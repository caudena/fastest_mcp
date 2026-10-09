defmodule FastestMCP.Middleware.ResponseCaching do
  @moduledoc false
  # Deliberately conservative: only successful results are cached; keys include
  # method, target, arguments, transport, auth context, and an explicit session
  # identity; oversized items are skipped, never truncated or stored partially.

  require Logger

  alias FastestMCP.Auth
  alias FastestMCP.BackgroundTask
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Middleware
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  @list_ttl_ms 5 * 60_000
  @read_ttl_ms 60 * 60_000

  # Cached methods, the option configuring each, and its default TTL.
  @collections [
    {"tools/list", :list_tools, @list_ttl_ms},
    {"resources/list", :list_resources, @list_ttl_ms},
    {"prompts/list", :list_prompts, @list_ttl_ms},
    {"resources/read", :read_resource, @read_ttl_ms},
    {"prompts/get", :get_prompt, @read_ttl_ms},
    {"tools/call", :call_tool, @read_ttl_ms}
  ]
  @fields Map.new(@collections, fn {method, field, _ttl_ms} -> {method, field} end)

  # The counters of a stats table row `{method, hits, misses, ...}`.
  @stats [:hits, :misses, :puts, :expired, :skipped_too_large, :evictions]
  @positions Map.new(Enum.with_index(@stats, 2))
  @zero_row Tuple.duplicate(0, length(@stats) + 1)

  defstruct [
    :instance_id,
    :runtime,
    :logger,
    :list_tools,
    :list_resources,
    :list_prompts,
    :read_resource,
    :get_prompt,
    :call_tool,
    cleanup_interval_ms: 60_000,
    max_item_size: 1_000_000
  ]

  @type ttl_ms :: pos_integer() | :infinity

  @type collection_settings :: %{
          enabled: boolean(),
          ttl_ms: ttl_ms()
        }

  @type call_tool_settings :: %{
          enabled: boolean(),
          ttl_ms: ttl_ms(),
          included_tools: MapSet.t(String.t()) | nil,
          excluded_tools: MapSet.t(String.t()) | nil
        }

  @type collection_stats :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          puts: non_neg_integer(),
          expired: non_neg_integer(),
          skipped_too_large: non_neg_integer(),
          evictions: non_neg_integer()
        }

  @type t :: %__MODULE__{
          instance_id: reference(),
          runtime: {cache :: :ets.tid(), stats :: :ets.tid()} | nil,
          logger: (String.t() -> any()),
          cleanup_interval_ms: pos_integer() | :infinity,
          list_tools: collection_settings(),
          list_resources: collection_settings(),
          list_prompts: collection_settings(),
          read_resource: collection_settings(),
          get_prompt: collection_settings(),
          call_tool: call_tool_settings(),
          max_item_size: pos_integer()
        }

  def new(opts \\ []) do
    max_item_size = max_item_size!(Keyword.get(opts, :max_item_size, 1_000_000))
    cleanup_interval_ms = cleanup_interval!(Keyword.get(opts, :cleanup_interval_ms, 60_000))

    settings =
      for {_method, field, ttl_ms} <- @collections,
          do: {field, settings!(field, Keyword.get(opts, field, []), ttl_ms)}

    struct!(
      %__MODULE__{
        instance_id: make_ref(),
        logger: Keyword.get(opts, :logger, &Logger.warning/1),
        cleanup_interval_ms: cleanup_interval_ms,
        max_item_size: max_item_size
      },
      settings
    )
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{runtime: nil} = middleware, _operation, _next),
    do: Middleware.not_running(middleware)

  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    with true <- cacheable_operation?(operation),
         true <- auth_scope(operation.context) != :unpartitionable,
         %{enabled: true} = settings <- collection_settings(middleware, operation) do
      key = {operation.method, cache_key(operation)}

      case lookup(middleware, key) do
        {:hit, result} ->
          {:ok, %{operation | result: result}}

        :miss ->
          with {:ok, done} <- next.(operation) do
            if cacheable_result?(done.result),
              do: store(middleware, key, done.result, settings.ttl_ms, operation)

            {:ok, done}
          end
      end
    else
      _uncached -> next.(operation)
    end
  end

  @impl FastestMCP.Middleware
  def child_spec(%__MODULE__{} = middleware), do: {__MODULE__.State, middleware}

  @impl FastestMCP.Middleware
  def attach(%__MODULE__{} = middleware, pid),
    do: %{middleware | runtime: GenServer.call(pid, :tables)}

  def statistics(%__MODULE__{} = middleware) do
    empty = Map.new(@stats, &{&1, 0})
    initial = Map.new(@collections, fn {method, _field, _ttl_ms} -> {method, empty} end)

    for {_cache, stats} <- Middleware.runtimes(middleware),
        row <- :ets.tab2list(stats),
        reduce: initial do
      acc ->
        [method | counts] = Tuple.to_list(row)

        Map.update!(acc, method, fn current ->
          Map.new(Enum.zip(@stats, counts), fn {stat, count} -> {stat, current[stat] + count} end)
        end)
    end
  end

  def cache_key(%Operation{} = operation) do
    %{
      server_name: operation.server_name,
      method: operation.method,
      target: operation.target,
      arguments: operation.arguments,
      version: operation.version,
      audience: operation.audience,
      transport: operation.transport,
      task_request: operation.task_request,
      explicit_session: explicit_session_scope(operation.context),
      auth: auth_scope(operation.context)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Deletes the expired entries, counting each as an eviction.
  def evict_expired({cache, stats}) do
    expired = :ets.select(cache, [{{:"$1", :"$2", :_}, [{:"=<", :"$2", now_ms()}], [:"$1"]}])

    Enum.each(expired, fn {method, _digest} = key ->
      :ets.delete(cache, key)
      bump(stats, method, :evictions)
    end)
  end

  defp lookup(%__MODULE__{runtime: {cache, stats}}, {method, _digest} = key) do
    case :ets.lookup(cache, key) do
      [{^key, expires_at, value}] ->
        if expires_at <= now_ms() do
          :ets.delete(cache, key)
          bump(stats, method, [:expired, :misses])
          :miss
        else
          bump(stats, method, :hits)
          {:hit, value}
        end

      [] ->
        bump(stats, method, :misses)
        :miss
    end
  end

  defp store(middleware, {method, _digest} = key, result, ttl_ms, operation) do
    {cache, stats} = middleware.runtime
    size = :erlang.external_size(result)

    if size > middleware.max_item_size do
      bump(stats, method, :skipped_too_large)

      middleware.logger.(
        "Skipping cache for #{operation.method} #{inspect(operation.target)} because #{size} bytes exceeds max_item_size=#{middleware.max_item_size}"
      )
    else
      :ets.insert(cache, {key, expires_at(ttl_ms), result})
      bump(stats, method, :puts)
    end
  end

  defp bump(stats, method, counters) do
    increments = for counter <- List.wrap(counters), do: {Map.fetch!(@positions, counter), 1}
    :ets.update_counter(stats, method, increments, put_elem(@zero_row, 0, method))
  end

  defp cacheable_operation?(%Operation{task_request: true}), do: false
  defp cacheable_operation?(%Operation{context: context}), do: not continuation?(context)

  defp continuation?(nil), do: false

  defp continuation?(context) do
    metadata = context_value(context, :request_metadata, %{})
    input_responses = context_value(context, :input_responses, %{})

    Map.get(metadata, :input_responses_provided) == true or
      Map.get(metadata, :request_state_provided) == true or
      (is_map(input_responses) and map_size(input_responses) > 0) or
      not is_nil(context_value(context, :request_state))
  end

  defp cacheable_result?(%InputRequiredResult{}), do: false
  defp cacheable_result?(%BackgroundTask{}), do: false
  defp cacheable_result?(%FastestMCP.Tools.Result{is_error: true}), do: false
  defp cacheable_result?(_result), do: true

  defp collection_settings(middleware, %Operation{method: method, target: target})
       when is_map_key(@fields, method) do
    settings = Map.fetch!(middleware, @fields[method])
    if method != "tools/call" or tool_allowed?(settings, to_string(target)), do: settings
  end

  defp collection_settings(_middleware, _operation), do: nil

  defp tool_allowed?(%{included_tools: included, excluded_tools: excluded}, tool_name) do
    (is_nil(included) or MapSet.member?(included, tool_name)) and
      (is_nil(excluded) or not MapSet.member?(excluded, tool_name))
  end

  defp settings!(field, opts, default_ttl_ms) do
    opts = Map.new(opts)

    settings = %{
      enabled: Map.get(opts, :enabled, true),
      ttl_ms: ttl_ms!(Map.get(opts, :ttl_ms, default_ttl_ms), field)
    }

    if field == :call_tool do
      Map.merge(settings, %{
        included_tools: tool_set!(opts[:included_tools]),
        excluded_tools: tool_set!(opts[:excluded_tools])
      })
    else
      settings
    end
  end

  defp max_item_size!(value) when is_integer(value) and value > 0, do: value

  defp max_item_size!(value) do
    raise ArgumentError, "max_item_size must be a positive integer, got #{inspect(value)}"
  end

  defp cleanup_interval!(:infinity), do: :infinity
  defp cleanup_interval!(value) when is_integer(value) and value > 0, do: value

  defp cleanup_interval!(value) do
    raise ArgumentError,
          "cleanup_interval_ms must be a positive integer or :infinity, got #{inspect(value)}"
  end

  defp ttl_ms!(:infinity, _field), do: :infinity
  defp ttl_ms!(value, _field) when is_integer(value) and value > 0, do: value

  defp ttl_ms!(value, field) do
    raise ArgumentError,
          "#{field}.ttl_ms must be a positive integer or :infinity, got #{inspect(value)}"
  end

  defp tool_set!(nil), do: nil
  defp tool_set!(tools) when is_list(tools), do: MapSet.new(tools, &to_string/1)

  defp tool_set!(tools) do
    raise ArgumentError, "tool filters must be lists, got #{inspect(tools)}"
  end

  # A monotonic deadline, or `:infinity`, which sorts after every integer and
  # so never expires.
  defp expires_at(:infinity), do: :infinity
  defp expires_at(ttl_ms), do: now_ms() + ttl_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp explicit_session_scope(nil), do: :implicit

  defp explicit_session_scope(context) do
    request_metadata = context_value(context, :request_metadata, %{})

    if Map.get(request_metadata, :session_id_provided, false),
      do: {:explicit, context_value(context, :session_id)},
      else: :implicit
  end

  defp auth_scope(nil), do: :anonymous

  defp auth_scope(context) do
    principal = context_value(context, :principal)
    authenticated = context_value(context, :authenticated, false)

    cond do
      authenticated and is_nil(principal) ->
        :unpartitionable

      is_nil(principal) and not authenticated and
        context_value(context, :auth) in [%{}, nil] and
        context_value(context, :capabilities) in [[], nil] and
        context_value(context, :verified_audiences) in [[], nil] and
          context_value(context, :verified_scopes) in [[], nil] ->
        :anonymous

      true ->
        Auth.authorization_partition(context)
    end
  end

  defp context_value(context, key, default \\ nil), do: Map.get(context, key, default)

  defmodule State do
    @moduledoc false
    # Owns the cache and statistics tables and evicts expired entries.

    use GenServer

    alias FastestMCP.Middleware
    alias FastestMCP.Middleware.ResponseCaching

    def start_link(middleware), do: GenServer.start_link(__MODULE__, middleware)

    @impl true
    def init(middleware) do
      options = [:public, read_concurrency: true, write_concurrency: true]
      tables = {:ets.new(__MODULE__.Cache, options), :ets.new(__MODULE__.Stats, options)}
      Middleware.register_runtime(middleware.instance_id, tables)
      schedule_cleanup(middleware.cleanup_interval_ms)
      {:ok, {tables, middleware.cleanup_interval_ms}}
    end

    @impl true
    def handle_call(:tables, _from, {tables, _interval_ms} = state),
      do: {:reply, tables, state}

    @impl true
    def handle_info(:cleanup, {tables, interval_ms} = state) do
      ResponseCaching.evict_expired(tables)
      schedule_cleanup(interval_ms)
      {:noreply, state}
    end

    defp schedule_cleanup(:infinity), do: :ok
    defp schedule_cleanup(interval_ms), do: Process.send_after(self(), :cleanup, interval_ms)
  end
end
