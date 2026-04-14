defmodule FastestMCP.Middleware.ResponseCaching do
  @moduledoc """
  TTL-backed response caching middleware for shared MCP operations.

  The cache is intentionally conservative:

  - it caches only successful results
  - cache keys include method, target, arguments, transport, auth context, and
    explicit session identity when present
  - oversized items are skipped instead of truncated or persisted partially
  """

  require Logger

  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Registry

  @default_list_ttl_ms 5 * 60_000
  @default_read_ttl_ms 60 * 60_000

  @collections [
    "tools/list",
    "resources/list",
    "prompts/list",
    "resources/read",
    "prompts/get",
    "tools/call"
  ]

  @hits_pos 2
  @misses_pos 3
  @puts_pos 4
  @expired_pos 5
  @skipped_pos 6
  defstruct [
    :instance_id,
    :runtime_id,
    :middleware,
    :state,
    :cache_table,
    :stats_table,
    :logger,
    cleanup_interval_ms: 60_000,
    list_tools: %{enabled: true, ttl_ms: @default_list_ttl_ms},
    list_resources: %{enabled: true, ttl_ms: @default_list_ttl_ms},
    list_prompts: %{enabled: true, ttl_ms: @default_list_ttl_ms},
    read_resource: %{enabled: true, ttl_ms: @default_read_ttl_ms},
    get_prompt: %{enabled: true, ttl_ms: @default_read_ttl_ms},
    call_tool: %{
      enabled: true,
      ttl_ms: @default_read_ttl_ms,
      included_tools: nil,
      excluded_tools: nil
    },
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
          runtime_id: reference() | nil,
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          state: pid() | nil,
          cache_table: :ets.tid() | nil,
          stats_table: :ets.tid() | nil,
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

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    max_item_size = validate_max_item_size!(Keyword.get(opts, :max_item_size, 1_000_000))

    cleanup_interval_ms =
      validate_cleanup_interval!(Keyword.get(opts, :cleanup_interval_ms, 60_000))

    middleware = %__MODULE__{
      instance_id: make_ref(),
      runtime_id: nil,
      state: nil,
      cache_table: nil,
      stats_table: nil,
      logger: Keyword.get(opts, :logger, &Logger.warning/1),
      cleanup_interval_ms: cleanup_interval_ms,
      list_tools:
        normalize_collection_settings(
          Keyword.get(opts, :list_tools, []),
          @default_list_ttl_ms,
          "list_tools"
        ),
      list_resources:
        normalize_collection_settings(
          Keyword.get(opts, :list_resources, []),
          @default_list_ttl_ms,
          "list_resources"
        ),
      list_prompts:
        normalize_collection_settings(
          Keyword.get(opts, :list_prompts, []),
          @default_list_ttl_ms,
          "list_prompts"
        ),
      read_resource:
        normalize_collection_settings(
          Keyword.get(opts, :read_resource, []),
          @default_read_ttl_ms,
          "read_resource"
        ),
      get_prompt:
        normalize_collection_settings(
          Keyword.get(opts, :get_prompt, []),
          @default_read_ttl_ms,
          "get_prompt"
        ),
      call_tool:
        normalize_call_tool_settings(Keyword.get(opts, :call_tool, []), @default_read_ttl_ms),
      max_item_size: max_item_size
    }

    bind_middleware(middleware)
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)

    if operation.task_request do
      next.(operation)
    else
      case collection_settings(middleware, operation) do
        nil ->
          next.(operation)

        {collection, settings} ->
          key = cache_key(operation)

          case lookup(middleware, collection, key) do
            {:hit, result} ->
              result

            :miss ->
              result = next.(operation)
              maybe_store(middleware, collection, key, result, settings[:ttl_ms], operation)
              result
          end
      end
    end
  end

  @doc "Returns runtime statistics for this module."
  def statistics(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.reduce(default_statistics(), fn runtime_middleware, stats ->
      Map.merge(stats, statistics_for_stats_table(runtime_middleware.stats_table), fn
        _collection, left, right ->
          Map.merge(left, right, fn _metric, left_value, right_value ->
            left_value + right_value
          end)
      end)
    end)
  end

  @doc "Releases resources owned by this module."
  def close(%__MODULE__{} = middleware), do: deactivate_runtime(middleware)

  @doc false
  def activate_runtime(%__MODULE__{} = middleware) do
    if middleware.runtime_id, do: deactivate_runtime(middleware)

    runtime_id = make_ref()

    {:ok, state} = __MODULE__.State.start_link(middleware.cleanup_interval_ms)
    {cache_table, stats_table} = __MODULE__.State.tables(state)

    runtime =
      middleware
      |> Map.put(:runtime_id, runtime_id)
      |> Map.put(:state, state)
      |> Map.put(:cache_table, cache_table)
      |> Map.put(:stats_table, stats_table)
      |> bind_middleware()

    :ok =
      Registry.register_middleware_runtime(middleware.instance_id, runtime_id, %{
        pid: state,
        cache_table: cache_table,
        stats_table: stats_table
      })

    runtime
  end

  @doc false
  def deactivate_runtime(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.each(fn %{runtime_id: runtime_id, state: pid} ->
      Registry.unregister_middleware_runtime(runtime_id)
      Middleware.shutdown_runtime_pid(pid)
    end)

    :ok
  end

  @doc false
  def state_pid(%__MODULE__{} = middleware) do
    case runtime_middleware(middleware) do
      %__MODULE__{state: state} -> state
      nil -> nil
    end
  end

  @doc "Builds the cache key for the given operation."
  def cache_key(%Operation{} = operation) do
    payload = %{
      server_name: operation.server_name,
      method: operation.method,
      target: operation.target,
      arguments: normalize_term(operation.arguments),
      version: operation.version,
      audience: operation.audience,
      transport: operation.transport,
      task_request: operation.task_request,
      explicit_session: explicit_session_scope(operation.context),
      auth: auth_scope(operation.context)
    }

    payload
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp lookup(%__MODULE__{} = middleware, collection, key) do
    now = now_ms()
    cache_key = {collection, key}

    case :ets.lookup(middleware.cache_table, cache_key) do
      [{^cache_key, expires_at, value}] ->
        if expired?(expires_at, now) do
          :ets.delete(middleware.cache_table, cache_key)
          bump_stat(middleware.stats_table, collection, @expired_pos)
          bump_stat(middleware.stats_table, collection, @misses_pos)
          :miss
        else
          bump_stat(middleware.stats_table, collection, @hits_pos)
          {:hit, value}
        end

      [] ->
        bump_stat(middleware.stats_table, collection, @misses_pos)
        :miss
    end
  end

  defp maybe_store(
         %__MODULE__{} = middleware,
         collection,
         key,
         result,
         ttl_ms,
         %Operation{} = operation
       ) do
    size = :erlang.external_size(result)

    if size > middleware.max_item_size do
      bump_stat(middleware.stats_table, collection, @skipped_pos)

      middleware.logger.(
        "Skipping cache for #{operation.method} #{inspect(operation.target)} because #{size} bytes exceeds max_item_size=#{middleware.max_item_size}"
      )
    else
      :ets.insert(middleware.cache_table, {{collection, key}, expires_at(ttl_ms), result})
      bump_stat(middleware.stats_table, collection, @puts_pos)
    end
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{method: "tools/list"}) do
    if middleware.list_tools.enabled, do: {"tools/list", middleware.list_tools}, else: nil
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{method: "resources/list"}) do
    if middleware.list_resources.enabled,
      do: {"resources/list", middleware.list_resources},
      else: nil
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{method: "prompts/list"}) do
    if middleware.list_prompts.enabled, do: {"prompts/list", middleware.list_prompts}, else: nil
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{method: "resources/read"}) do
    if middleware.read_resource.enabled,
      do: {"resources/read", middleware.read_resource},
      else: nil
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{method: "prompts/get"}) do
    if middleware.get_prompt.enabled, do: {"prompts/get", middleware.get_prompt}, else: nil
  end

  defp collection_settings(%__MODULE__{} = middleware, %Operation{
         method: "tools/call",
         target: target
       }) do
    settings = middleware.call_tool

    if settings.enabled and tool_allowed?(settings, target) do
      {"tools/call", settings}
    else
      nil
    end
  end

  defp collection_settings(_middleware, _operation), do: nil

  defp tool_allowed?(%{included_tools: included, excluded_tools: excluded}, target) do
    tool_name = to_string(target)

    include? =
      case included do
        nil -> true
        set -> MapSet.member?(set, tool_name)
      end

    exclude? =
      case excluded do
        nil -> false
        set -> MapSet.member?(set, tool_name)
      end

    include? and not exclude?
  end

  defp normalize_collection_settings(opts, default_ttl_ms, label) do
    opts = Map.new(opts)

    %{
      enabled: Map.get(opts, :enabled, Map.get(opts, "enabled", true)),
      ttl_ms:
        validate_ttl_ms!(
          Map.get(opts, :ttl_ms, Map.get(opts, "ttl_ms", default_ttl_ms)),
          label
        )
    }
  end

  defp normalize_call_tool_settings(opts, default_ttl_ms) do
    opts = Map.new(opts)

    %{
      enabled: Map.get(opts, :enabled, Map.get(opts, "enabled", true)),
      ttl_ms:
        validate_ttl_ms!(
          Map.get(opts, :ttl_ms, Map.get(opts, "ttl_ms", default_ttl_ms)),
          "call_tool"
        ),
      included_tools:
        normalize_tool_set(Map.get(opts, :included_tools, Map.get(opts, "included_tools"))),
      excluded_tools:
        normalize_tool_set(Map.get(opts, :excluded_tools, Map.get(opts, "excluded_tools")))
    }
  end

  defp validate_max_item_size!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_item_size!(value) do
    raise ArgumentError, "max_item_size must be a positive integer, got #{inspect(value)}"
  end

  defp validate_cleanup_interval!(:infinity), do: :infinity
  defp validate_cleanup_interval!(value) when is_integer(value) and value > 0, do: value

  defp validate_cleanup_interval!(value) do
    raise ArgumentError,
          "cleanup_interval_ms must be a positive integer or :infinity, got #{inspect(value)}"
  end

  defp validate_ttl_ms!(:infinity, _label), do: :infinity
  defp validate_ttl_ms!(value, _label) when is_integer(value) and value > 0, do: value

  defp validate_ttl_ms!(value, label) do
    raise ArgumentError,
          "#{label}.ttl_ms must be a positive integer or :infinity, got #{inspect(value)}"
  end

  defp normalize_tool_set(nil), do: nil

  defp normalize_tool_set(tools) when is_list(tools),
    do: MapSet.new(Enum.map(tools, &to_string/1))

  defp normalize_tool_set(tools) do
    raise ArgumentError, "tool filters must be lists, got #{inspect(tools)}"
  end

  defp expired?(:infinity, _now), do: false
  defp expired?(expires_at, now), do: expires_at <= now

  defp expires_at(:infinity), do: :infinity
  defp expires_at(ttl_ms), do: now_ms() + ttl_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp explicit_session_scope(nil), do: :implicit

  defp explicit_session_scope(context) do
    if session_id_provided?(context) do
      {:explicit, context_value(context, :session_id)}
    else
      :implicit
    end
  end

  defp session_id_provided?(context) do
    request_metadata = context_value(context, :request_metadata, %{})

    Map.get(
      request_metadata,
      :session_id_provided,
      Map.get(request_metadata, "session_id_provided", false)
    )
  end

  defp auth_scope(nil), do: :anonymous

  defp auth_scope(context) do
    principal = context_value(context, :principal)
    auth = context_value(context, :auth, %{})
    capabilities = context_value(context, :capabilities, [])

    if is_nil(principal) and auth in [%{}, nil] and capabilities in [[], nil] do
      :anonymous
    else
      %{
        principal: normalize_term(principal),
        auth: normalize_term(auth || %{}),
        capabilities: normalize_term(capabilities || [])
      }
    end
  end

  defp context_value(context, key, default \\ nil)
  defp context_value(nil, _key, default), do: default

  defp context_value(context, key, default) when is_map(context) do
    Map.get(context, key, Map.get(context, Atom.to_string(key), default))
  end

  defp normalize_term(%_{} = struct) do
    {:struct, struct.__struct__, normalize_term(Map.from_struct(struct))}
  end

  defp normalize_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {normalize_term(key), normalize_term(value)} end)
    |> Enum.sort()
  end

  defp normalize_term(list) when is_list(list), do: Enum.map(list, &normalize_term/1)

  defp normalize_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_term/1)
    |> List.to_tuple()
  end

  defp normalize_term(other), do: other

  defp default_statistics do
    Enum.into(@collections, %{}, fn collection ->
      {collection,
       %{
         hits: 0,
         misses: 0,
         puts: 0,
         expired: 0,
         skipped_too_large: 0,
         evictions: 0
       }}
    end)
  end

  defp bump_stat(stats_table, collection, position) do
    :ets.update_counter(stats_table, collection, {position, 1}, {collection, 0, 0, 0, 0, 0, 0})
  end

  defp statistics_for_stats_table(stats_table) do
    stats_table
    |> :ets.tab2list()
    |> Enum.into(default_statistics(), fn {collection, hits, misses, puts, expired, skipped,
                                           evictions} ->
      {collection,
       %{
         hits: hits,
         misses: misses,
         puts: puts,
         expired: expired,
         skipped_too_large: skipped,
         evictions: evictions
       }}
    end)
  end

  defp ensure_runtime(%__MODULE__{} = middleware) do
    runtime_middleware(middleware) || activate_runtime(middleware)
  end

  defp runtime_middleware(%__MODULE__{} = middleware) do
    case runtime_middlewares(middleware) do
      [runtime] -> runtime
      _other -> nil
    end
  end

  defp runtime_middlewares(%__MODULE__{runtime_id: runtime_id} = middleware)
       when is_reference(runtime_id) do
    case Registry.lookup_middleware_runtime(runtime_id) do
      {:ok, runtime} -> [hydrate_runtime(middleware, runtime)]
      {:error, :not_found} -> []
    end
  end

  defp runtime_middlewares(%__MODULE__{} = middleware) do
    middleware.instance_id
    |> Registry.list_middleware_runtimes()
    |> Enum.map(&hydrate_runtime(middleware, &1))
  end

  defp hydrate_runtime(
         %__MODULE__{} = middleware,
         %{runtime_id: runtime_id, pid: pid, cache_table: cache_table, stats_table: stats_table}
       ) do
    middleware
    |> Map.put(:runtime_id, runtime_id)
    |> Map.put(:state, pid)
    |> Map.put(:cache_table, cache_table)
    |> Map.put(:stats_table, stats_table)
    |> bind_middleware()
  end

  defp bind_middleware(%__MODULE__{} = middleware) do
    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  defmodule State do
    @moduledoc """
    State process that owns the ETS tables used by the response cache.
    """

    use GenServer

    @evictions_pos 7

    @doc "Starts the cache state process."
    def start_link(cleanup_interval_ms) do
      GenServer.start_link(__MODULE__, cleanup_interval_ms)
    end

    @doc "Returns the ETS tables backing the cache and statistics store."
    def tables(pid) do
      GenServer.call(pid, :tables)
    end

    @impl true
    @doc "Initializes the cache ETS tables and cleanup schedule."
    def init(cleanup_interval_ms) do
      cache_table =
        :ets.new(__MODULE__.Cache, [
          :set,
          :public,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      stats_table =
        :ets.new(__MODULE__.Stats, [
          :set,
          :public,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      maybe_schedule_cleanup(cleanup_interval_ms)

      {:ok,
       %{
         cleanup_interval_ms: cleanup_interval_ms,
         cache_table: cache_table,
         stats_table: stats_table
       }}
    end

    @impl true
    @doc "Processes synchronous inspection requests for the response-cache table."
    def handle_call(:tables, _from, state) do
      {:reply, {state.cache_table, state.stats_table}, state}
    end

    @impl true
    @doc "Runs periodic cleanup of expired cache entries."
    def handle_info(:cleanup, state) do
      now = System.monotonic_time(:millisecond)

      expired_keys =
        :ets.foldl(
          fn
            {{collection, key}, expires_at, _value}, acc ->
              if expires_at != :infinity and expires_at <= now do
                [{collection, {collection, key}} | acc]
              else
                acc
              end
          end,
          [],
          state.cache_table
        )

      Enum.each(expired_keys, fn {collection, cache_key} ->
        :ets.delete(state.cache_table, cache_key)

        :ets.update_counter(
          state.stats_table,
          collection,
          {@evictions_pos, 1},
          {collection, 0, 0, 0, 0, 0, 0}
        )
      end)

      maybe_schedule_cleanup(state.cleanup_interval_ms)
      {:noreply, state}
    end

    defp maybe_schedule_cleanup(:infinity), do: :ok

    defp maybe_schedule_cleanup(interval_ms),
      do: Process.send_after(self(), :cleanup, interval_ms)
  end
end
