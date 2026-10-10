defmodule FastestMCP.Context do
  @moduledoc ~S"""
  The context of the request a handler serves.

  Every handler receives it as its second argument, `ctx`. Through it, a
  handler keeps state, sends log messages and progress to the client, reads the
  server's other resources and prompts, and finds out who is calling. The
  [Context](context.md) guide covers each of these.

  ```elixir
  FastestMCP.server("visits")
  |> FastestMCP.add_tool("visit", fn _args, ctx ->
    visits = FastestMCP.Context.get_state(ctx, :visits, 0) + 1
    :ok = FastestMCP.Context.set_state(ctx, :visits, visits)
    FastestMCP.Context.info(ctx, "visit number #{visits}")
    %{visits: visits}
  end)
  ```

  Code that runs inside a handler but does not receive `ctx` can reach the
  context of the current request with `current/0` and `current!/0`.
  """

  import FastestMCP.Util, only: [maybe_put: 3, string_keys: 1]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Elicitation
  alias FastestMCP.Elicitation.URL, as: URLElicitation
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.HTTPRequest
  alias FastestMCP.InputRounds
  alias FastestMCP.JSONValue
  alias FastestMCP.Notifications
  alias FastestMCP.OperationPipeline
  alias FastestMCP.PeerTask
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.Progress, as: ProgressProtocol
  alias FastestMCP.Protocol.Redactor
  alias FastestMCP.Protocol.Sampling, as: SamplingProtocol
  alias FastestMCP.RequestContext
  alias FastestMCP.Root
  alias FastestMCP.SamplingTool
  alias FastestMCP.Session
  alias FastestMCP.ServerRuntime

  require Logger

  @excluded_http_headers ["accept", "content-length", "content-type", "host"]
  @private_http_headers ["authorization"]
  @visibility_rules_key {:fastest_mcp, :visibility_rules}
  @reserved_notification_methods MapSet.new([
                                   "notifications/cancelled",
                                   "notifications/elicitation/complete",
                                   "notifications/initialized",
                                   "notifications/message",
                                   "notifications/progress",
                                   "notifications/prompts/list_changed",
                                   "notifications/resources/list_changed",
                                   "notifications/resources/updated",
                                   "notifications/roots/list_changed",
                                   "notifications/tasks/status",
                                   "notifications/tools/list_changed"
                                 ])
  @notification_envelope_keys MapSet.new(["jsonrpc", "method", "params"])
  @options [
    :request_id,
    :session_id,
    :request_state,
    :input_responses,
    :transport_authorization,
    :negotiated_protocol_version,
    :principal,
    transport: :in_process,
    state_scope: :session,
    request_metadata: %{},
    client_capabilities: %{},
    server_capabilities: %{},
    task_metadata: %{},
    authenticated: false,
    auth: %{},
    capabilities: [],
    verified_audiences: [],
    verified_scopes: []
  ]
  @option_keys Enum.map(@options, fn
                 {key, _default} -> key
                 key -> key
               end)
  @inherited [
    :session_id,
    :transport,
    :state_scope,
    :negotiated_protocol_version,
    :client_capabilities,
    :request_metadata,
    :transport_authorization,
    :principal,
    :authenticated,
    :auth,
    :capabilities,
    :verified_audiences,
    :verified_scopes
  ]

  @derive {Inspect, except: [:auth, :transport_authorization]}
  defstruct [
    :server_name,
    :server,
    :session_id,
    :request_id,
    :transport,
    :state_scope,
    :negotiated_protocol_version,
    :request_state,
    :event_bus,
    :task_store,
    :session_state_store,
    :application_session_scope,
    :principal,
    :transport_authorization,
    authenticated: false,
    auth: %{},
    capabilities: [],
    verified_audiences: [],
    verified_scopes: [],
    client_capabilities: %{},
    server_capabilities: %{},
    lifespan_context: %{},
    dependencies: %{},
    request_metadata: %{},
    input_responses: %{},
    task_metadata: %{}
  ]

  @type t :: %__MODULE__{
          server_name: String.t(),
          server: FastestMCP.Server.t() | nil,
          session_id: String.t() | nil,
          request_id: String.t(),
          transport: atom(),
          state_scope: :request | :session,
          negotiated_protocol_version: String.t() | nil,
          request_state: String.t() | nil,
          event_bus: struct(),
          task_store: pid() | atom() | nil,
          session_state_store: map() | nil,
          application_session_scope: String.t(),
          principal: any(),
          transport_authorization: String.t() | nil,
          authenticated: boolean(),
          auth: map(),
          capabilities: [any()],
          verified_audiences: [String.t()],
          verified_scopes: [String.t()],
          client_capabilities: map(),
          server_capabilities: map(),
          lifespan_context: map(),
          dependencies: map(),
          request_metadata: map(),
          input_responses: map(),
          task_metadata: map()
        }

  @doc """
  Builds the context of one request to a running server.

  `runtime` is the server's runtime snapshot, which supplies the server, its
  dependencies, stores, event bus, and lifespan context. Building a context has
  no side effects: it does not start the session it names.

  A context without a `:session_id` is request-scoped, whatever its
  `:state_scope`: it has no session, and the state it sets lasts for the
  request.

  Options: `:transport` (default `:in_process`), `:state_scope` (`:session`,
  the default, or `:request`), `:request_id` (a new one by default),
  `:session_id`, `:request_metadata`,
  `:transport_authorization`, `:negotiated_protocol_version`,
  `:client_capabilities`, `:server_capabilities`, `:input_responses`,
  `:request_state`, `:task_metadata`, and the auth fields `:principal`,
  `:authenticated`, `:auth`, `:capabilities`, `:verified_audiences`, and
  `:verified_scopes`.
  """
  def new(%ServerRuntime{} = runtime, opts \\ []) do
    opts = Keyword.validate!(opts, @options)
    state_scope = Keyword.fetch!(opts, :state_scope)

    unless state_scope in [:request, :session] do
      raise ArgumentError, "state_scope must be :request or :session, got #{inspect(state_scope)}"
    end

    session_id = session_id!(opts[:session_id])

    {request_metadata, metadata_authorization} =
      split_transport_authorization(Map.new(opts[:request_metadata] || %{}))

    %__MODULE__{
      server_name: runtime.server.name,
      server: runtime.server,
      session_id: session_id,
      request_id: opts[:request_id] || new_request_id(),
      transport: opts[:transport],
      state_scope: if(session_id, do: state_scope, else: :request),
      negotiated_protocol_version: opts[:negotiated_protocol_version],
      request_state: opts[:request_state],
      event_bus: runtime.event_bus,
      task_store: runtime.task_store,
      session_state_store: runtime.session_state_store,
      application_session_scope: runtime.server.name,
      principal: opts[:principal],
      transport_authorization:
        normalize_transport_authorization(opts[:transport_authorization]) ||
          metadata_authorization,
      authenticated: opts[:authenticated],
      auth: opts[:auth] || %{},
      capabilities: normalize_capabilities(opts[:capabilities]),
      verified_audiences: List.wrap(opts[:verified_audiences]),
      verified_scopes: List.wrap(opts[:verified_scopes]),
      client_capabilities: opts[:client_capabilities] || %{},
      server_capabilities: opts[:server_capabilities] || %{},
      lifespan_context: runtime.lifespan_context,
      dependencies: normalize_dependencies(runtime.server.dependencies),
      request_metadata:
        request_metadata
        |> Map.put_new(:input_responses_provided, Keyword.has_key?(opts, :input_responses))
        |> Map.put_new(:request_state_provided, Keyword.has_key?(opts, :request_state)),
      input_responses: Map.new(opts[:input_responses] || %{}),
      task_metadata: Map.new(opts[:task_metadata])
    }
  end

  @doc false
  # The id of a new request, as `new/2` gives one.
  def new_request_id, do: "req-" <> Integer.to_string(System.unique_integer([:positive]))

  @doc false
  # The `new/2` options among an operation's `opts`. A nested operation on the
  # server of the current context inherits that context's session and identity
  # for the options it does not set. A context without a session has no state
  # scope to pass on: a nested operation that names a session uses it.
  def inherit_opts(server_name, opts) do
    opts = Keyword.take(opts, @option_keys)

    case current() do
      %__MODULE__{server_name: ^server_name} = context ->
        inherited = if context.session_id, do: @inherited, else: @inherited -- [:state_scope]

        context
        |> Map.take(inherited)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Keyword.merge(opts)

      _other ->
        opts
    end
  end

  @doc "Runs the given function with this context installed as the current request context."
  def with_request(%__MODULE__{} = context, fun) when is_function(fun, 0) do
    previous = current()
    Process.put({__MODULE__, :current_context}, context)

    try do
      try do
        fun.()
      after
        run_dependency_cleanups(context)
      end
    after
      restore_current(previous)
      clear_request_state(context)
    end
  end

  @doc """
  Returns the current request context for the calling process.

  This is the narrow convenience helper for nested runtime code. It returns
  `nil` when the current process is not executing inside a FastestMCP request.
  """
  def current do
    Process.get({__MODULE__, :current_context})
  end

  @doc """
  Returns the current request context or raises when no request is active.

  Use this when helper code is only valid inside an active FastestMCP request
  and should fail loudly otherwise.
  """
  def current! do
    case current() do
      %__MODULE__{} = context ->
        context

      nil ->
        raise RuntimeError,
              "FastestMCP.Context.current!/0 requires an active FastestMCP request context"
    end
  end

  @doc "Stores request-scoped state on the context."
  def put_request_state(%__MODULE__{} = context, key, value) do
    scope = {__MODULE__, :request_state, context.request_id}
    Process.put(scope, Map.put(Process.get(scope, %{}), key, value))
    :ok
  end

  @doc "Reads request-scoped state from the context."
  def get_request_state(%__MODULE__{} = context, key, default \\ nil) do
    Process.get({__MODULE__, :request_state, context.request_id}, %{}) |> Map.get(key, default)
  end

  @doc "Deletes one request-scoped value from the context."
  def delete_request_state(%__MODULE__{} = context, key) do
    scope = {__MODULE__, :request_state, context.request_id}
    Process.put(scope, Map.delete(Process.get(scope, %{}), key))
    :ok
  end

  @doc "Registers cleanup work to run when the current request scope exits."
  def register_cleanup(%__MODULE__{} = context, cleanup) when is_function(cleanup, 0) do
    maybe_register_dependency_cleanup(context, nil, cleanup)
  end

  def register_cleanup(%__MODULE__{} = context, cleanup) when is_function(cleanup, 1) do
    maybe_register_dependency_cleanup(context, nil, fn -> cleanup.(context) end)
  end

  def register_cleanup(%__MODULE__{}, cleanup) do
    raise ArgumentError,
          "request cleanup must be a zero-arity function or a one-arity context callback, got: #{inspect(cleanup)}"
  end

  @doc """
  Returns the client's answers to the input requests of the handler's own
  `FastestMCP.InputRequiredResult`, by key: those of the latest round, or of
  every round so far in a background task. Answers to the questions of the
  helpers aren't included.
  """
  def input_responses(%__MODULE__{} = context), do: context.input_responses

  @doc """
  Returns the request state of the handler's own `FastestMCP.InputRequiredResult`,
  which the client sent back, or `nil`.
  """
  def request_state(%__MODULE__{} = context), do: context.request_state

  @doc false
  def transport_authorization(%__MODULE__{} = context), do: context.transport_authorization

  @doc "Returns the definition of the server handling the request."
  def server(%__MODULE__{} = context), do: context.server

  @doc """
  Builds a stable request-context snapshot from the current context.

  `%FastestMCP.Context{}` is still the primary runtime object. This helper is
  the narrower convenience surface for code that wants request metadata without
  depending on the full context struct.

  ## Example

  ```elixir
  FastestMCP.add_tool(server, "request_info", fn _arguments, ctx ->
    request = FastestMCP.Context.request_context(ctx)

    %{
      request_id: request.request_id,
      transport: request.transport,
      path: request.path
    }
  end)
  ```
  """
  def request_context(%__MODULE__{} = context) do
    %RequestContext{
      request_id: context.request_id,
      transport: context.transport,
      path: context.request_metadata[:path],
      query_params: context.request_metadata[:query_params] || %{},
      headers: request_metadata_headers(context),
      meta: request_context_meta(context)
    }
  end

  @doc """
  Returns the `_meta` that the client sent with its request, a map with string
  keys, or `%{}` when it sent none, as in an in-process call. On `2026-07-28` it
  also holds the protocol's own keys, such as
  `"io.modelcontextprotocol/clientInfo"`.
  """
  def request_meta(%__MODULE__{} = context) do
    case context.request_metadata[:jsonrpc_envelope] do
      %{"params" => %{"_meta" => %{} = meta}} -> meta
      _no_meta -> %{}
    end
  end

  @doc """
  Returns the client id of the caller's verified identity, or `nil`.

  It is the `client_id` (or `clientId`) in `ctx.auth`, else the `client_id`,
  `clientId`, or `sub` of `ctx.principal`, with atom or string keys. The name
  that a client reports for itself is unverified, so it is never used; read it
  from the [request metadata](context.md#request-metadata).
  """
  def client_id(%__MODULE__{} = context) do
    Auth.claim(context.auth, [:client_id, :clientId]) ||
      Auth.claim(context.principal, [:client_id, :clientId, :sub])
  end

  @doc "Returns the background-task store attached to the context, if present."
  def task_store(%__MODULE__{} = context), do: context.task_store || request_task_store(context)

  @doc "Returns the dependency map available on the context."
  def dependencies(%__MODULE__{} = context) do
    Map.keys(context.dependencies)
  end

  @doc "Resolves one named dependency from the context."
  def dependency(%__MODULE__{} = context, name) do
    key = normalize_dependency_name(name)

    case Map.fetch(context.dependencies, key) do
      {:ok, resolver} ->
        # Keyed by resolver too: a mounted server's handler shares the request
        # with the servers it is mounted in, whose resolvers may differ.
        cache_key = {:dependency, key, resolver}

        case get_request_state(context, cache_key, :__missing__) do
          :__missing__ -> resolve_and_cache_dependency(context, resolver, key, cache_key)
          value -> value
        end

      :error ->
        raise ArgumentError,
              "unknown dependency #{inspect(name)} for server #{inspect(context.server_name)}"
    end
  end

  defp resolve_and_cache_dependency(context, resolver, key, cache_key) do
    {value, cleanup} = resolve_dependency(resolver, context, key)
    :ok = put_request_state(context, cache_key, value)
    maybe_register_dependency_cleanup(context, value, cleanup)
    value
  end

  @doc "Stores session-scoped state for the current session."
  def put_session_state(%__MODULE__{} = context, key, value) do
    set_state(context, key, value)
  end

  @doc "Reads session-scoped state for the current session."
  def get_session_state(%__MODULE__{} = context, key, default \\ nil) do
    get_state(context, key, default)
  end

  @doc "Stores state for the current context."
  def set_state(%__MODULE__{} = context, key, value, opts \\ []) do
    if context.state_scope == :session and Keyword.get(opts, :serializable, true) do
      :ok = delete_request_state(context, {:state, key})
      Session.put(context.server_name, context.session_id, key, value)
    else
      put_request_state(context, {:state, key}, value)
    end
  end

  @doc "Reads state for the current context."
  def get_state(%__MODULE__{} = context, key, default \\ nil) do
    case get_request_state(context, {:state, key}, :__missing__) do
      :__missing__ ->
        if context.state_scope == :session do
          Session.get(context.server_name, context.session_id, key, default)
        else
          default
        end

      value ->
        value
    end
  end

  @doc "Deletes state for the current context."
  def delete_state(%__MODULE__{} = context, key) do
    :ok = delete_request_state(context, {:state, key})

    if context.state_scope == :session do
      Session.delete(context.server_name, context.session_id, key)
    else
      :ok
    end
  end

  @doc "Stores a resolved auth result on the context."
  def put_auth_result(%__MODULE__{} = context, %Result{} = result) do
    audiences =
      if result.audiences == [] and is_list(result.verified_audiences),
        do: result.verified_audiences,
        else: result.audiences

    scopes =
      if result.scopes == [] and is_list(result.verified_scopes),
        do: result.verified_scopes,
        else: result.scopes

    %{
      context
      | principal: result.principal,
        authenticated: true,
        auth: result.auth || %{},
        capabilities: normalize_capabilities(result.capabilities),
        verified_audiences: audiences,
        verified_scopes: scopes
    }
  end

  @doc "Returns the request's `FastestMCP.Progress` tracker."
  def progress(%__MODULE__{} = context) do
    FastestMCP.Progress.new(context)
  end

  @doc """
  Sends a log message at `level` to the client of the request, and returns
  `:ok`, `:filtered` when no client receives it (below the level the client
  asked for, or a request without a client, such as an in-process call), or
  `{:error, reason}`; see [Levels and results](context.md#levels-and-results).
  """
  def log(%__MODULE__{} = context, level, data, opts \\ []) do
    level = normalize_log_level(level)

    result =
      cond do
        is_modern(context.negotiated_protocol_version) ->
          deliver_modern_log(context, level, data, opts)

        is_nil(context.session_id) ->
          :filtered

        true ->
          Session.log(context.server_name, context.session_id, level, data, opts)
      end

    # The event carries the message as the client receives it, redacted.
    case result do
      {:ok, sent} ->
        emit(context, [:log, :message], %{count: 1}, %{
          level: level,
          logger: Keyword.get(opts, :logger),
          data: sent
        })

        :ok

      not_sent ->
        not_sent
    end
  end

  defp deliver_modern_log(context, level, data, opts) do
    requested_level = request_log_level(context)

    cond do
      is_nil(requested_level) ->
        :filtered

      Meta.log_level_rank(level) < (Meta.log_level_rank(requested_level) || 0) ->
        :filtered

      true ->
        case request_stream_sink(context) do
          {pid, stream_ref} when is_pid(pid) ->
            params =
              %{
                "level" => level,
                "data" => Redactor.redact(data, opts)
              }
              |> maybe_put("logger", Keyword.get(opts, :logger))

            send(
              pid,
              {:fastest_mcp_request_stream_message, stream_ref,
               %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/message",
                 "params" => params
               }}
            )

            {:ok, params["data"]}

          # The request is answered without a stream, which could carry it.
          _no_stream ->
            :filtered
        end
    end
  end

  @doc """
  Sends a notification of your own to the client of the `2025-11-25` session,
  and returns `{:ok, delivery}`. A notification is a method name with
  optional `params`, or a whole JSON-RPC notification map.

  The names of standard MCP notifications return `{:error, :reserved_method}`,
  and a request without a session (on `2026-07-28`, or in process without
  `session_id:`) returns `{:error, :no_session}`.
  """
  def send_notification(context, method, params \\ %{})

  def send_notification(%__MODULE__{} = context, method, params)
      when is_binary(method) and (is_map(params) or is_nil(params)) do
    if MapSet.member?(@reserved_notification_methods, method) do
      {:error, :reserved_method}
    else
      envelope = maybe_put(%{"jsonrpc" => "2.0", "method" => method}, "params", params)
      deliver_notification(context, envelope)
    end
  end

  def send_notification(%__MODULE__{} = context, %{} = notification, _params) do
    with {:ok, notification} <- normalize_extension_notification(notification),
         false <- MapSet.member?(@reserved_notification_methods, notification["method"]) do
      deliver_notification(context, notification)
    else
      true -> {:error, :reserved_method}
      {:error, reason} -> {:error, reason}
    end
  end

  # Notifications of the handler's own travel in the client's session.
  defp deliver_notification(%__MODULE__{session_id: nil}, _envelope), do: {:error, :no_session}

  defp deliver_notification(%__MODULE__{} = context, envelope) do
    Session.send_envelope(
      context.server_name,
      context.session_id,
      envelope,
      session_delivery_opts(context, queue: true)
    )
  end

  @doc "Emits a debug log event from this context."
  def debug(%__MODULE__{} = context, data, opts \\ []), do: log(context, :debug, data, opts)

  @doc "Emits an info log event from this context."
  def info(%__MODULE__{} = context, data, opts \\ []), do: log(context, :info, data, opts)

  @doc "Emits a warning log event from this context."
  def warning(%__MODULE__{} = context, data, opts \\ []), do: log(context, :warning, data, opts)

  @doc "Emits an error log event from this context."
  def error(%__MODULE__{} = context, data, opts \\ []), do: log(context, :error, data, opts)

  @doc """
  Asks the client's model for a completion and returns the client's result, a
  map with string keys such as
  `%{"role" => "assistant", "model" => "...", "content" => %{"type" => "text", "text" => "..."}}`.

  `prompt_or_messages` is a prompt or a list of sampling messages, with atom or
  string keys. The options are those of `FastestMCP.Sampling.run!/3`, without
  `:max_tool_rounds`: this function runs no tools for the model. With
  `task: true`, a client in a `2025-11-25` session may run the request as a
  task of its own, and the function returns a `FastestMCP.PeerTask`. See
  [What works where](sampling-and-elicitation.md#what-works-where) for how the
  request reaches the client.
  """
  def sample(context, prompt_or_messages, opts \\ [])

  def sample(%__MODULE__{} = context, prompt, opts) when is_binary(prompt) do
    message = %{"role" => "user", "content" => %{"type" => "text", "text" => prompt}}
    sample(context, [message], opts)
  end

  def sample(%__MODULE__{} = context, messages, opts) when is_list(messages) do
    # Messages with atom keys or values, as the client receives them.
    messages = messages |> JSONValue.encode!() |> JSON.decode!()
    SamplingProtocol.validate_messages!(messages)
    tools = sampling_tool_definitions(Keyword.get(opts, :tools))
    include_context = normalize_sampling_include_context(Keyword.get(opts, :include_context))

    params =
      %{
        "messages" => messages,
        "maxTokens" => Keyword.get(opts, :max_tokens, 100)
      }
      |> maybe_put("systemPrompt", Keyword.get(opts, :system_prompt))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("stopSequences", Keyword.get(opts, :stop_sequences))
      |> maybe_put("_meta", Keyword.get(opts, :meta))
      |> maybe_put("metadata", Keyword.get(opts, :metadata))
      |> maybe_put("modelPreferences", Keyword.get(opts, :model_preferences))
      |> maybe_put("includeContext", include_context)
      |> maybe_put("tools", tools)
      |> maybe_put_sampling_tool_choice(tools, Keyword.get(opts, :tool_choice, :auto))
      |> maybe_put_task_request(opts)

    route = client_route!(context, "sampling", opts)
    validate_sampling_capabilities!(context, tools, include_context)
    validate_peer_task_capability!(context, opts, ["sampling", "createMessage"])
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    result =
      context
      |> ask!(route, "sampling/createMessage", params, timeout_ms, opts)
      |> validate_sampling_result!(tools, opts)

    normalize_peer_task_or_result(context, result, :sampling, "sampling/createMessage")
  end

  @doc """
  Asks the client for its roots, the `file://` folders the user works in, and
  returns them as `FastestMCP.Root` structs.

  A `2025-11-25` session keeps the roots until the client reports a change;
  `refresh: true` asks anyway. `timeout_ms:` (default 60 seconds) bounds the
  wait where the handler waits for the answer.
  """
  def list_roots(%__MODULE__{} = context, opts \\ []) do
    route = client_route!(context, "roots", opts)

    require_client_capability!(
      context,
      ["roots"],
      "connected client did not declare roots support"
    )

    with nil <- if(!Keyword.get(opts, :refresh, false), do: cached_roots(context)) do
      case ask!(context, route, "roots/list", %{}, Keyword.get(opts, :timeout_ms, 60_000), opts) do
        %{"roots" => roots} when is_list(roots) -> keep_roots!(context, roots)
        other -> raise invalid_roots(other)
      end
    end
  end

  @doc "Returns the roots cached for this session, or nil before the first successful request."
  def cached_roots(%__MODULE__{session_id: nil}), do: nil

  def cached_roots(%__MODULE__{} = context) do
    case Session.cached_roots(context.server_name, context.session_id) do
      roots when is_list(roots) -> roots
      _none_or_no_session -> nil
    end
  end

  @doc """
  Lists the tasks of the client of this `2025-11-25` session. A request
  without a session raises an `:internal_error` that says so.
  """
  def list_peer_tasks(%__MODULE__{} = context, opts \\ []) do
    require_session!(context, "Context.list_peer_tasks/2", "")

    require_client_capability!(
      context,
      ["tasks", "list"],
      "connected client did not declare tasks.list support"
    )

    params =
      case Keyword.get(opts, :cursor) do
        nil -> %{}
        cursor when is_binary(cursor) -> %{"cursor" => cursor}
        cursor -> raise ArgumentError, "cursor must be a string, got: #{inspect(cursor)}"
      end

    result =
      send_client_request(
        context,
        "tasks/list",
        params,
        Keyword.get(opts, :timeout_ms, 60_000),
        opts
      )

    %{
      items: Map.fetch!(result, "tasks"),
      next_cursor: Map.get(result, "nextCursor")
    }
  end

  @doc """
  Sends an MCP ping to the client of a `2025-11-25` session and returns `:ok`
  once it answers. `2026-07-28` has no ping from the server.
  """
  def ping_peer(%__MODULE__{} = context, opts \\ []) do
    route = client_route!(context, "a ping", opts)
    require_legacy!(context, "Context.ping_peer/2", "2026-07-28 has no ping from the server")

    case ask!(context, route, "ping", %{}, Keyword.get(opts, :timeout_ms, 60_000), opts) do
      %{} = result when map_size(result) == 0 -> :ok
      %{} -> {:error, :invalid_ping_result}
    end
  end

  @doc """
  Asks the client of a `2025-11-25` session to send the user to a page of your
  application (URL elicitation). Returns the structs of `elicit/4`; see
  [Sending the user to a web page](sampling-and-elicitation.md#sending-the-user-to-a-web-page).
  """
  def elicit_url(%__MODULE__{} = context, message, url_or_builder, opts \\ []) do
    route = client_route!(context, "URL elicitation", opts)
    require_url_session!(context)

    require_client_capability!(
      context,
      ["elicitation", "url"],
      "connected client did not declare elicitation.url support"
    )

    validate_peer_task_capability!(context, opts, ["elicitation", "create"])

    elicitation = build_and_register_url_elicitation!(context, message, url_or_builder, opts)
    params = elicitation |> URLElicitation.to_params() |> maybe_put_task_request(opts)

    result =
      ask!(
        context,
        route,
        "elicitation/create",
        params,
        Keyword.get(opts, :timeout_ms, 60_000),
        opts
      )

    case normalize_peer_task_or_result(context, result, :elicitation, "elicitation/create") do
      %PeerTask{} = task ->
        task

      %{"action" => action} = response ->
        case Session.resolve_url_elicitation(
               context.server_name,
               context.session_id,
               elicitation.elicitation_id,
               action,
               Map.get(response, "content")
             ) do
          {:ok, updated} ->
            url_elicitation_result(updated)

          {:error, reason} ->
            raise Error,
              code: :bad_request,
              message: "invalid URL elicitation response",
              details: %{reason: inspect(reason)}
        end

      _other ->
        raise Error, code: :bad_request, message: "invalid URL elicitation response"
    end
  end

  @doc """
  Registers a URL elicitation in the `2025-11-25` session and raises the
  standard `-32042` error (`:url_elicitation_required`), which carries the URL
  to the client.
  """
  @spec require_url_elicitation!(t(), term(), term()) :: no_return()
  @spec require_url_elicitation!(t(), term(), term(), keyword()) :: no_return()
  def require_url_elicitation!(%__MODULE__{} = context, message, url_or_builder, opts \\ []) do
    require_url_session!(context)

    require_client_capability!(
      context,
      ["elicitation", "url"],
      "connected client did not declare elicitation.url support"
    )

    elicitation = build_and_register_url_elicitation!(context, message, url_or_builder, opts)
    raise URLElicitation.required_error([elicitation])
  end

  @doc "Returns the current access token available on the context."
  def access_token(%__MODULE__{} = context) do
    request_access_token(context) || Auth.claim(context.auth, [:token])
  end

  @doc "Lists visible resources using the current request context."
  def list_resources(%__MODULE__{} = context) do
    context.server_name
    |> OperationPipeline.list_resources(inherited_operation_opts(context))
    |> Error.unwrap!()
  end

  @doc "Reads a resource using the current request context."
  def read_resource(%__MODULE__{} = context, uri) do
    context.server_name
    |> OperationPipeline.read_resource(uri, inherited_operation_opts(context))
    |> Error.unwrap!()
  end

  @doc "Notifies subscribed sessions that one concrete resource URI changed."
  def notify_resource_updated(%__MODULE__{} = context, uri) do
    FastestMCP.notify_resource_updated!(context.server_name, uri)
  end

  @doc "Lists visible prompts using the current request context."
  def list_prompts(%__MODULE__{} = context) do
    context.server_name
    |> OperationPipeline.list_prompts(inherited_operation_opts(context))
    |> Error.unwrap!()
  end

  @doc "Renders a prompt using the current request context."
  def render_prompt(%__MODULE__{} = context, name, arguments \\ %{}) do
    context.server_name
    |> OperationPipeline.render_prompt(name, arguments, inherited_operation_opts(context))
    |> Error.unwrap!()
  end

  @doc """
  Shows the matching components to the session of the request only; see
  [Per-session visibility](versioning-and-visibility.md#per-session-visibility).
  A request without a session (on `2026-07-28`, or in process without
  `session_id:`) raises an `:internal_error`; `FastestMCP.enable_components/2`
  changes what every client sees.
  """
  def enable_components(%__MODULE__{} = context, opts \\ []) do
    update_visibility_rules(context, :enable, opts)
  end

  @doc """
  Hides the matching components from the session of the request only; like
  `enable_components/2`, it needs a session.
  """
  def disable_components(%__MODULE__{} = context, opts \\ []) do
    update_visibility_rules(context, :disable, opts)
  end

  @doc "Clears the visibility rules of the request's session, which it needs."
  def reset_visibility(%__MODULE__{} = context) do
    require_session!(context, "Context.reset_visibility/1", "")
    before = visible_component_sets(context)
    :ok = delete_state(context, @visibility_rules_key)
    emit_visibility_change(context, before, visible_component_sets(context))
    :ok
  end

  @doc "Returns the immutable HTTP request snapshot for this context."
  def http_request(%__MODULE__{} = context) do
    method = context.request_metadata[:method]
    path = context.request_metadata[:path]
    query_params = context.request_metadata[:query_params] || %{}
    headers = request_metadata_headers(context)

    if is_nil(method) and is_nil(path) and map_size(headers) == 0 and
         map_size(Map.new(query_params)) == 0 do
      nil
    else
      %HTTPRequest{
        method: method && to_string(method),
        path: path && to_string(path),
        query_params: Map.new(query_params),
        headers: headers
      }
    end
  end

  @doc "Returns HTTP headers captured on the current request context."
  def http_headers(%__MODULE__{} = context, opts \\ []) do
    headers =
      case http_request(context) do
        %HTTPRequest{headers: headers} -> headers
        nil -> %{}
      end

    public_headers = Map.drop(headers, @private_http_headers)

    if Keyword.get(opts, :include_all, false) do
      public_headers
    else
      Map.drop(public_headers, @excluded_http_headers)
    end
  end

  @doc "Builds a derived context for background-task execution."
  def for_background_task(%__MODULE__{} = context, task_id, opts \\ []) do
    task_metadata =
      context.task_metadata
      |> Map.merge(%{
        task_id: to_string(task_id),
        origin_request_id: context.request_id,
        origin_transport: context.transport,
        poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000)
      })
      |> maybe_put(:task_store, Keyword.get(opts, :task_store))

    %{
      context
      | request_id: "task-req-" <> Integer.to_string(System.unique_integer([:positive])),
        transport: :background_task,
        transport_authorization: nil,
        request_metadata: context.request_metadata |> split_transport_authorization() |> elem(0),
        task_metadata: task_metadata
    }
  end

  @doc "Returns whether the context belongs to background-task execution."
  @deprecated "Use background_task?/1"
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_background_task(%__MODULE__{} = context), do: not is_nil(task_id(context))
  @doc "Returns whether the context belongs to background-task execution."
  def background_task?(%__MODULE__{} = context), do: not is_nil(task_id(context))

  @doc "Returns the current background-task id, if any."
  def task_id(%__MODULE__{} = context) do
    context.task_metadata[:task_id]
  end

  @doc "Returns the original request id that created the background task, if any."
  def origin_request_id(%__MODULE__{} = context) do
    context.task_metadata[:origin_request_id]
  end

  @doc "Records a progress update."
  def report_progress(%__MODULE__{} = context, current, total \\ nil, message \\ nil) do
    with {:ok, next_total} <- validate_progress_update(context, current, total) do
      progress =
        %{}
        |> maybe_put(:current, current)
        |> maybe_put(:total, total)
        |> maybe_put(:message, message)
        |> Map.put(:reported_at, System.system_time(:millisecond))

      stored? = store_task_progress(context, progress)
      delivery = deliver_progress(context, current, total, message)

      if modern_progress?(context) and (delivery == :ok or stored?) do
        put_request_state(context, :progress_update, %{current: current, total: next_total})
      end

      # A background task's progress is the task's; any other is its request's.
      if background_task?(context),
        do: emit(context, [:task, :progress], progress, %{task_id: task_id(context)}),
        else: emit(context, [:operation, :progress], progress)

      delivery
    end
  end

  defp validate_progress_update(%__MODULE__{} = context, current, total) do
    if modern_progress?(context) do
      previous = get_request_state(context, :progress_update, %{current: nil, total: nil})
      supplied_total = if is_nil(total), do: :absent, else: {:provided, total}

      ProgressProtocol.validate_update(
        current,
        previous.current,
        supplied_total,
        previous.total
      )
    else
      {:ok, total}
    end
  end

  defp store_task_progress(%__MODULE__{} = context, progress) do
    case {task_store(context), task_id(context)} do
      {store, task_id} when not is_nil(store) and is_binary(task_id) and task_id != "" ->
        BackgroundTaskStore.report_progress(store, task_id, progress) == :ok

      _other ->
        false
    end
  end

  defp deliver_progress(%__MODULE__{} = context, current, total, message) do
    case progress_token(context) do
      nil ->
        {:error, :missing_progress_token}

      token ->
        params =
          %{
            "progressToken" => token,
            "progress" => current
          }
          |> maybe_put("total", total)
          |> maybe_put("message", message)

        case request_stream_sink(context) do
          {pid, stream_ref} when is_pid(pid) ->
            send(
              pid,
              {:fastest_mcp_request_stream_message, stream_ref,
               %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/progress",
                 "params" => params
               }}
            )

            :ok

          # Neither a stream nor a session carries it: as without a token.
          _no_stream when is_nil(context.session_id) ->
            {:error, :missing_progress_token}

          _no_stream ->
            Session.report_progress(
              context.server_name,
              context.session_id,
              protocol_request_id(context),
              Map.delete(params, "progressToken")
            )
        end
    end
  end

  defp modern_progress?(%__MODULE__{negotiated_protocol_version: modern()}), do: true
  defp modern_progress?(%__MODULE__{}), do: false

  @doc """
  Asks the user for form input of `response_type` and returns the answer:
  `%FastestMCP.Elicitation.Accepted{data: data}`,
  `%FastestMCP.Elicitation.Declined{}`, or `%FastestMCP.Elicitation.Cancelled{}`.
  With `task: true`, a client in a `2025-11-25` session may answer as a task
  of its own, and the function returns a `FastestMCP.PeerTask`.

  The request reaches the client through the handler's background task,
  through a multi-round-trip request on `2026-07-28`, or through the
  `2025-11-25` session; see
  [What works where](sampling-and-elicitation.md#what-works-where).
  `timeout_ms:` (default 60 seconds) bounds the wait where the handler waits
  for the answer.
  """
  def elicit(%__MODULE__{} = context, message, response_type, opts \\ []) do
    request = Elicitation.request(message, response_type, opts)

    case client_route!(context, "elicitation", opts) do
      :task ->
        interact!(context, :elicitation, request, request.timeout_ms)

      route ->
        require_form_elicitation!(context)
        validate_peer_task_capability!(context, opts, ["elicitation", "create"])

        params =
          %{
            "mode" => "form",
            "message" => request.message,
            "requestedSchema" => request.requested_schema
          }
          |> maybe_put_task_request(opts)

        result = ask!(context, route, "elicitation/create", params, request.timeout_ms, opts)

        case normalize_peer_task_or_result(context, result, :elicitation, "elicitation/create") do
          %PeerTask{} = task ->
            task

          %{} = answer ->
            case Elicitation.resolve(request, answer["action"], answer["content"]) do
              {:ok, resolved} -> resolved
              {:error, %Error{} = error} -> raise error
            end
        end
    end
  end

  @doc "Emits telemetry and local runtime events for this context."
  def emit(%__MODULE__{} = context, event_suffix, measurements \\ %{}, metadata \\ %{}) do
    EventBus.emit(
      context.event_bus,
      context.server_name,
      event_suffix,
      measurements,
      Map.merge(base_metadata(context), metadata)
    )
  end

  @doc "Builds the base metadata shared across telemetry and event emission."
  def base_metadata(%__MODULE__{} = context) do
    %{
      server_name: context.server_name,
      session_id: context.session_id,
      request_id: context.request_id,
      transport: context.transport
    }
    |> maybe_put(:task_id, task_id(context))
    |> maybe_put(:origin_request_id, origin_request_id(context))
  end

  defp clear_request_state(%__MODULE__{} = context) do
    Process.delete({__MODULE__, :request_state, context.request_id})
  end

  defp restore_current(nil), do: Process.delete({__MODULE__, :current_context})

  defp restore_current(%__MODULE__{} = context),
    do: Process.put({__MODULE__, :current_context}, context)

  defp normalize_dependencies(dependencies) when is_list(dependencies) or is_map(dependencies) do
    dependencies
    |> Enum.into(%{}, fn {name, resolver} -> {normalize_dependency_name(name), resolver} end)
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities), do: capabilities
  defp normalize_capabilities(nil), do: []
  defp normalize_capabilities(capability), do: List.wrap(capability)

  # How a request of the handler reaches the client: through its background
  # task, as a multi-round-trip request (2026-07-28), or through its
  # 2025-11-25 session. Only a session takes `task:` requests.
  defp client_route!(%__MODULE__{} = context, what, opts) do
    route =
      cond do
        background_task?(context) -> :task
        InputRounds.active?(context) -> :rounds
        is_binary(context.session_id) -> :session
        true -> raise no_client(context, what)
      end

    if route != :session and Keyword.get(opts, :task, false) != false do
      raise Error,
        code: :bad_request,
        message:
          "task: true asks the client to run the request as a task of its own, " <>
            "which needs a tool call in a 2025-11-25 session"
    end

    route
  end

  defp no_client(%__MODULE__{} = context, what) do
    hint =
      if is_modern(context.negotiated_protocol_version),
        do:
          "on 2026-07-28, ask in the handler of a client's tools/call, prompts/get, or " <>
            "resources/read request, in the handler's own process, or in a background task",
        else:
          "make the call through a client, or run it as a background task (task: true) " <>
            "and answer with FastestMCP.send_task_input/5 or FastestMCP.update_task/4"

    %Error{
      code: :internal_error,
      message: "the request has no client to ask for #{what}: #{hint}"
    }
  end

  # Sends `method` to the client by `route` and returns the answer.
  defp ask!(context, :task, method, params, timeout_ms, _opts),
    do: interact!(context, :request, %{"method" => method, "params" => params}, timeout_ms)

  defp ask!(context, :rounds, method, params, _timeout_ms, _opts),
    do: InputRounds.ask!(context, %{"method" => method, "params" => params})

  defp ask!(context, :session, method, params, timeout_ms, opts),
    do: send_client_request(context, method, params, timeout_ms, opts)

  # A background task reaches the client through its task store.
  defp interact!(%__MODULE__{} = context, kind, request, timeout_ms) do
    store = task_store(context) || raise "background task context is missing its task store"

    case BackgroundTaskStore.interact(store, task_id(context), kind, request, timeout_ms) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise Error,
          code: :not_found,
          message: "unknown background task #{inspect(task_id(context))}"
    end
  end

  defp request_task_store(%__MODULE__{} = context) do
    context.task_metadata[:task_store]
  end

  defp progress_token(%__MODULE__{} = context) do
    context.request_metadata[:progress_token]
  end

  defp request_stream_sink(%__MODULE__{} = context) do
    context.request_metadata[:request_stream_sink]
  end

  defp request_log_level(%__MODULE__{} = context) do
    context.request_metadata[:log_level]
  end

  defp send_client_request(%__MODULE__{} = context, method, params, timeout_ms, opts) do
    request_opts =
      session_delivery_opts(context,
        timeout_ms: timeout_ms,
        on_progress: Keyword.get(opts, :on_progress),
        progress_token: Keyword.get(opts, :progress_token)
      )
      |> maybe_put_related_task_delivery(context)

    params = attach_related_task_params(context, params)

    case Session.request_peer(
           context.server_name,
           context.session_id,
           method,
           params,
           request_opts
         ) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :timeout} ->
        raise Error,
          code: :timeout,
          message: "#{method} timed out",
          details: %{timeout_ms: timeout_ms}

      {:error, reason} when reason in [:not_found, :not_initialized, :not_deliverable] ->
        raise Error,
          code: :internal_error,
          message:
            "#{method} cannot reach the client: session #{inspect(context.session_id)} " <>
              "has no initialized client with an open stream",
          details: %{reason: reason}

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp maybe_put_related_task_delivery(opts, context) do
    case task_id(context) do
      task_id when is_binary(task_id) and task_id != "" ->
        Keyword.put(opts, :protocol_related_task_id, task_id)

      _other ->
        opts
    end
  end

  defp session_delivery_opts(%__MODULE__{} = context, opts) do
    opts
    |> Keyword.put_new(:sink_ref, context.request_metadata[:session_sink_ref])
    |> Keyword.put_new(:origin_request_id, protocol_request_id(context))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp protocol_request_id(%__MODULE__{} = context) do
    context.request_metadata[:jsonrpc_request_id] || context.request_id
  end

  defp attach_related_task_params(%__MODULE__{} = context, params) do
    case task_id(context) do
      task_id when is_binary(task_id) and task_id != "" ->
        meta = Map.get(params, "_meta", %{})

        Map.put(
          params,
          "_meta",
          Map.put(meta, "io.modelcontextprotocol/related-task", %{"taskId" => task_id})
        )

      _other ->
        params
    end
  end

  defp validate_sampling_result!(%{"task" => %{}} = result, _tools, _opts),
    do: result

  defp validate_sampling_result!(result, tools, opts) do
    tool_choice = if is_nil(tools), do: nil, else: Keyword.get(opts, :tool_choice, :auto)
    SamplingProtocol.validate_result!(result, tool_choice)
    result
  end

  defp normalize_peer_task_or_result(
         %__MODULE__{} = context,
         %{"task" => %{} = task},
         kind,
         target
       ) do
    task_id = Map.get(task, "taskId")

    if is_binary(task_id) and task_id != "" do
      PeerTask.new(
        server_name: context.server_name,
        session_id: context.session_id,
        task_id: task_id,
        kind: kind,
        target: target
      )
    else
      raise Error, code: :bad_request, message: "peer task result is missing taskId"
    end
  end

  defp normalize_peer_task_or_result(_context, result, _kind, _target), do: result

  defp maybe_put_task_request(params, opts) do
    case Keyword.get(opts, :task, false) do
      false ->
        params

      true ->
        Map.put(params, "task", %{})

      task_opts when is_list(task_opts) ->
        task =
          %{}
          |> maybe_put("ttl", Keyword.get(task_opts, :ttl))

        Map.put(params, "task", task)

      other ->
        raise ArgumentError,
              "task must be true, false, or keyword options, got: #{inspect(other)}"
    end
  end

  # The roots of a roots/list answer, which a session keeps.
  defp keep_roots!(%__MODULE__{} = context, roots) do
    roots =
      Enum.map(roots, fn root ->
        case Root.parse(root) do
          {:ok, root} -> root
          {:error, reason} -> raise invalid_roots(reason)
        end
      end)

    if context.session_id,
      do: Session.cache_roots(context.server_name, context.session_id, roots)

    roots
  end

  defp invalid_roots(reason) do
    %Error{
      code: :bad_request,
      message: "invalid roots/list result",
      details: %{reason: inspect(reason)}
    }
  end

  defp require_client_capability!(%__MODULE__{} = context, path, message) do
    if Protocol.capability?(context.client_capabilities, path) do
      :ok
    else
      missing_capability!(context, path, message)
    end
  end

  # On 2026-07-28, an empty `elicitation` object declares form support.
  defp require_form_elicitation!(%__MODULE__{client_capabilities: capabilities} = context) do
    if Protocol.capability?(capabilities, ["elicitation", "form"]) or
         Protocol.capability(capabilities, ["elicitation"]) == %{} do
      :ok
    else
      missing_capability!(
        context,
        ["elicitation", "form"],
        "connected client did not declare elicitation.form support"
      )
    end
  end

  defp missing_capability!(%__MODULE__{} = context, path, message) do
    if is_modern(context.negotiated_protocol_version) do
      raise Error,
        code: :missing_required_client_capability,
        message: message,
        details: %{
          jsonrpc_code: -32_021,
          requiredCapabilities: Protocol.capabilities_map([path])
        }
    else
      raise Error, code: :method_not_found, message: message
    end
  end

  # Requests that only a 2025-11-25 session can send.
  defp require_legacy!(%__MODULE__{} = context, subject, reason) do
    if is_modern(context.negotiated_protocol_version) do
      raise Error,
        code: :method_not_found,
        message: "#{subject} needs a 2025-11-25 session: #{reason}"
    end
  end

  # Session visibility rules and client tasks belong to a session, which a
  # 2026-07-28 request and an in-process call without `session_id:` don't have.
  defp require_session!(%__MODULE__{session_id: nil}, subject, hint) do
    raise Error,
      code: :internal_error,
      message: "#{subject} needs a 2025-11-25 session, which this request doesn't have" <> hint
  end

  defp require_session!(%__MODULE__{}, _subject, _hint), do: :ok

  # URL elicitations are bound to a 2025-11-25 session, which notifies the
  # client when they complete.
  defp require_url_session!(%__MODULE__{} = context) do
    reason = "2026-07-28 has no URL elicitation ids or completion notifications"
    require_legacy!(context, "URL elicitation", reason)

    if is_nil(context.session_id) do
      raise Error,
        code: :method_not_found,
        message: "URL elicitation needs a 2025-11-25 session, which this request doesn't have"
    end
  end

  defp build_and_register_url_elicitation!(context, message, url_or_builder, opts) do
    do_build_and_register_url_elicitation!(context, message, url_or_builder, opts, 8)
  end

  defp do_build_and_register_url_elicitation!(
         context,
         message,
         url_or_builder,
         opts,
         attempts_remaining
       ) do
    elicitation = build_url_elicitation!(context, message, url_or_builder, opts)

    case Session.register_url_elicitation(
           context.server_name,
           context.session_id,
           elicitation
         ) do
      :ok ->
        elicitation

      {:error, :already_exists} when attempts_remaining > 1 ->
        do_build_and_register_url_elicitation!(
          context,
          message,
          url_or_builder,
          opts,
          attempts_remaining - 1
        )

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to claim URL elicitation id",
          details: %{reason: inspect(reason)}
    end
  end

  defp build_url_elicitation!(context, message, url_or_builder, opts) do
    if is_nil(context.principal) do
      raise Error,
        code: :forbidden,
        message: "URL elicitation requires a verified non-anonymous identity"
    end

    allowed_hosts =
      Keyword.get(opts, :allowed_hosts) ||
        (context.server && Map.get(context.server, :url_elicitation_allowed_hosts))

    principal_fingerprint = Auth.identity_fingerprint(context.principal, context.auth)

    URLElicitation.new!(message, url_or_builder,
      session_id: context.session_id,
      principal_fingerprint: principal_fingerprint,
      allowed_hosts: allowed_hosts,
      ttl_ms: Keyword.get(opts, :ttl_ms, 15 * 60_000),
      purpose: Keyword.get(opts, :purpose, :external_interaction)
    )
  end

  defp url_elicitation_result(%{action: :accept} = elicitation),
    do: %Elicitation.Accepted{
      data: %{elicitation_id: elicitation.elicitation_id, url: elicitation.url}
    }

  defp url_elicitation_result(%{action: :decline}), do: %Elicitation.Declined{}
  defp url_elicitation_result(%{action: :cancel}), do: %Elicitation.Cancelled{}
  defp url_elicitation_result(_elicitation), do: %Elicitation.Cancelled{}

  defp inherited_operation_opts(%__MODULE__{} = context) do
    [
      session_id: context.session_id,
      transport: context.transport,
      request_metadata: context.request_metadata,
      transport_authorization: context.transport_authorization,
      principal: context.principal,
      authenticated: context.authenticated,
      auth: context.auth,
      capabilities: context.capabilities,
      verified_audiences: context.verified_audiences,
      verified_scopes: context.verified_scopes,
      transport_authenticated: context.authenticated,
      task_metadata: context.task_metadata
    ]
  end

  defp update_visibility_rules(%__MODULE__{} = context, action, opts) do
    require_session!(
      context,
      "Context.#{action}_components/2",
      "; FastestMCP.#{action}_components/2 changes what every client sees"
    )

    before = visible_component_sets(context)
    rules = get_state(context, @visibility_rules_key, [])
    next_rules = List.wrap(rules) ++ ComponentVisibility.normalize_rules(action, opts)
    :ok = set_state(context, @visibility_rules_key, next_rules)
    emit_visibility_change(context, before, visible_component_sets(context))
    :ok
  end

  defp visible_component_sets(%__MODULE__{} = context) do
    context.server_name
    |> OperationPipeline.visible_component_sets(inherited_operation_opts(context))
    |> Error.unwrap!()
  end

  defp emit_visibility_change(_context, before_sets, after_sets)
       when before_sets == after_sets,
       do: :ok

  # The lists of one session changed: only that session is notified.
  defp emit_visibility_change(%__MODULE__{} = context, before_sets, after_sets) do
    families =
      [:tools, :resources, :prompts]
      |> Enum.filter(&(Map.get(before_sets, &1, []) != Map.get(after_sets, &1, [])))

    with [_family | _rest] <- families,
         {:ok, runtime} <- ServerRuntime.fetch(context.server_name),
         do: Notifications.list_changed(runtime, families, base_metadata(context))
  end

  defp request_metadata_headers(%__MODULE__{} = context) do
    context.request_metadata[:headers]
    |> normalize_headers()
    |> Map.drop(@private_http_headers)
  end

  defp request_context_meta(%__MODULE__{} = context) do
    meta =
      context.request_metadata
      |> string_keys()
      |> Map.drop(~w(headers path query_params request_stream_sink authorization))

    case request_client_info(context) do
      %{} = client_info ->
        Map.put_new(meta, "clientInfo", client_info)

      _other ->
        meta
    end
  end

  defp request_access_token(%__MODULE__{} = context) do
    context.transport_authorization
    |> Kernel.||(legacy_request_authorization(context.request_metadata))
    |> case do
      "Bearer " <> token when token != "" -> token
      _other -> nil
    end
  end

  defp legacy_request_authorization(request_metadata) do
    {_public_metadata, authorization} = split_transport_authorization(request_metadata)
    authorization
  end

  # The client info of an initialize request, else of the session; string keys.
  defp request_client_info(%__MODULE__{} = context) do
    context.request_metadata[:clientInfo] ||
      if(context.session_id, do: Session.client_info(context.server_name, context.session_id))
  end

  defp resolve_dependency(resolver, context, key) when is_function(resolver, 0) do
    normalize_dependency_result(resolver.(), context, key)
  end

  defp resolve_dependency(resolver, context, key) when is_function(resolver, 1) do
    normalize_dependency_result(resolver.(context), context, key)
  end

  defp normalize_dependency_result({:ok, value}, _context, _key), do: {value, nil}

  defp normalize_dependency_result({:ok, value, cleanup}, _context, _key),
    do: {value, cleanup}

  defp normalize_dependency_result({:error, %Error{} = error}, _context, _key), do: raise(error)

  defp normalize_dependency_result({:error, reason}, context, key) do
    raise Error,
      code: :internal_error,
      message: "dependency #{inspect(key)} failed",
      details: %{server_name: context.server_name, reason: inspect(reason)}
  end

  defp normalize_dependency_result(value, _context, _key), do: {value, nil}

  defp maybe_register_dependency_cleanup(_context, _value, nil), do: :ok

  defp maybe_register_dependency_cleanup(context, value, cleanup) do
    stack = get_request_state(context, :dependency_cleanups, [])
    put_request_state(context, :dependency_cleanups, [{cleanup, value} | stack])
  end

  defp run_dependency_cleanups(%__MODULE__{} = context) do
    context
    |> get_request_state(:dependency_cleanups, [])
    |> Enum.each(fn {cleanup, value} ->
      run_dependency_cleanup_safely(cleanup, value, context)
    end)
  end

  defp run_dependency_cleanup_safely(cleanup, value, context) do
    _ = run_dependency_cleanup(cleanup, value, context)
    :ok
  rescue
    error ->
      Logger.error("dependency cleanup failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("dependency cleanup failed: #{kind}: #{inspect(reason)}")
      :ok
  end

  defp run_dependency_cleanup(cleanup, _value, _context) when is_function(cleanup, 0),
    do: cleanup.()

  defp run_dependency_cleanup(cleanup, value, _context) when is_function(cleanup, 1),
    do: cleanup.(value)

  defp run_dependency_cleanup(cleanup, value, context) when is_function(cleanup, 2),
    do: cleanup.(value, context)

  defp normalize_dependency_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_dependency_name(name) when is_binary(name), do: name

  defp normalize_headers(nil), do: %{}

  defp normalize_headers(headers) do
    headers
    |> Enum.into(%{}, fn
      {key, value} when is_atom(key) ->
        {key |> Atom.to_string() |> String.downcase(), to_string(value)}

      {key, value} ->
        {key |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp split_transport_authorization(request_metadata) do
    headers =
      request_metadata
      |> Map.get(:headers, Map.get(request_metadata, "headers", %{}))
      |> Map.new()

    authorization =
      headers
      |> Enum.find_value(fn {key, value} ->
        if authorization_key?(key),
          do: normalize_transport_authorization(value)
      end)
      |> Kernel.||(
        request_metadata
        |> Enum.find_value(fn {key, value} ->
          if authorization_key?(key),
            do: normalize_transport_authorization(value)
        end)
      )

    public_headers =
      Map.reject(headers, fn {key, _value} ->
        authorization_key?(key)
      end)

    public_metadata =
      request_metadata
      |> Map.reject(fn {key, _value} -> authorization_key?(key) end)
      |> Map.delete(:headers)
      |> Map.delete("headers")
      |> Map.put(:headers, public_headers)

    {public_metadata, authorization}
  end

  defp normalize_transport_authorization(value) when is_binary(value) and value != "", do: value
  defp normalize_transport_authorization(_value), do: nil

  defp authorization_key?(key) when is_binary(key) or is_atom(key),
    do: String.downcase(to_string(key)) == "authorization"

  defp authorization_key?(_key), do: false

  defp normalize_extension_notification(notification) do
    canonical_keys = Enum.map(Map.keys(notification), &canonical_notification_key/1)

    with false <- Enum.any?(canonical_keys, &is_nil/1),
         true <- length(canonical_keys) == MapSet.size(MapSet.new(canonical_keys)),
         true <- MapSet.subset?(MapSet.new(canonical_keys), @notification_envelope_keys),
         normalized <- JSONValue.stringify_keys(notification),
         true <- Map.get(normalized, "jsonrpc", "2.0") == "2.0",
         method when is_binary(method) and method != "" <- Map.get(normalized, "method"),
         true <- valid_notification_params?(normalized) do
      {:ok, Map.put(normalized, "jsonrpc", "2.0")}
    else
      _other -> {:error, :invalid_notification}
    end
  end

  defp canonical_notification_key(key) when is_binary(key), do: key
  defp canonical_notification_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_notification_key(_key), do: nil

  defp valid_notification_params?(notification) do
    case Map.fetch(notification, "params") do
      :error -> true
      {:ok, params} -> is_map(params)
    end
  end

  defp normalize_log_level(level) when is_atom(level),
    do: level |> Atom.to_string() |> normalize_log_level()

  defp normalize_log_level(level) when is_binary(level) do
    if Meta.log_level_rank(level) do
      level
    else
      raise ArgumentError, "unsupported log level #{inspect(level)}"
    end
  end

  defp sampling_tool_definitions(nil), do: nil
  defp sampling_tool_definitions([]), do: nil

  defp sampling_tool_definitions(tools) when is_list(tools) do
    Enum.map(tools, fn
      %SamplingTool{} = tool -> SamplingTool.definition(tool)
      %{} = definition -> Map.new(definition, fn {key, value} -> {to_string(key), value} end)
      other -> raise ArgumentError, "invalid sampling tool #{inspect(other)}"
    end)
  end

  defp validate_sampling_capabilities!(context, tools, include_context) do
    require_client_capability!(
      context,
      ["sampling"],
      "connected client did not declare sampling support"
    )

    cond do
      not is_nil(tools) and not client_sampling_capability?(context, "tools") ->
        raise Error,
          code: :bad_request,
          message: "connected client did not declare sampling.tools support"

      include_context in ["thisServer", "allServers"] and
          not client_sampling_capability?(context, "context") ->
        raise Error,
          code: :bad_request,
          message: "connected client did not declare sampling.context support"

      true ->
        :ok
    end
  end

  defp validate_peer_task_capability!(context, opts, request_path) do
    if Keyword.get(opts, :task, false) == false do
      :ok
    else
      require_client_capability!(
        context,
        ["tasks", "requests" | request_path],
        "connected client did not declare task support for #{Enum.join(request_path, "/")}"
      )
    end
  end

  defp client_sampling_capability?(%__MODULE__{client_capabilities: capabilities}, key) do
    Protocol.capability?(capabilities, ["sampling", key]) or
      Protocol.capability?(capabilities, [:sampling, sampling_capability_atom(key)])
  end

  defp sampling_capability_atom("tools"), do: :tools
  defp sampling_capability_atom("context"), do: :context

  defp normalize_sampling_include_context(nil), do: nil
  defp normalize_sampling_include_context(:none), do: "none"
  defp normalize_sampling_include_context(:this_server), do: "thisServer"
  defp normalize_sampling_include_context(:all_servers), do: "allServers"

  defp normalize_sampling_include_context(value)
       when value in ["none", "thisServer", "allServers"],
       do: value

  defp normalize_sampling_include_context(other) do
    raise ArgumentError,
          "include_context must be :none, :this_server, :all_servers, or the corresponding MCP value, got #{inspect(other)}"
  end

  defp maybe_put_sampling_tool_choice(params, nil, _choice), do: params

  defp maybe_put_sampling_tool_choice(params, _tools, choice) do
    Map.put(params, "toolChoice", sampling_tool_choice(choice))
  end

  defp sampling_tool_choice(choice) when choice in [:auto, :required, :none],
    do: %{"mode" => Atom.to_string(choice)}

  defp sampling_tool_choice(other) do
    raise ArgumentError,
          "tool_choice must be :auto, :required, or :none, got #{inspect(other)}"
  end

  defp session_id!(nil), do: nil

  defp session_id!(session_id) do
    case to_string(session_id) do
      "" -> raise ArgumentError, "session_id must not be empty"
      session_id -> session_id
    end
  end
end
