defmodule FastestMCP.Context do
  @moduledoc ~S"""
  Explicit request context passed to handlers.

  `FastestMCP.Context` is where FastestMCP makes runtime lifetimes visible
  instead of hiding them behind injected globals or rewritten function
  signatures.

  A context carries four different kinds of state:

    * request state - metadata and scratch values that live for one operation
    * session state - values stored in a per-session process and reused across
      multiple requests
    * auth state - principal, raw auth payload, and capability data resolved by
      `FastestMCP.Auth`
    * task state - metadata needed when the current operation is running as a
      background task
    * request metadata - a transport snapshot that can be exposed as
      `%FastestMCP.RequestContext{}`

  ## Example

  ```elixir
  FastestMCP.add_tool(server, "visit", fn _arguments, ctx ->
    visits = FastestMCP.Context.get_session_state(ctx, :visits, 0) + 1
    :ok = FastestMCP.Context.put_session_state(ctx, :visits, visits)

    %{
      visits: visits,
      server: ctx.server_name
    }
  end)
  ```

  ## Why The Context Is Explicit

  Handler signatures stay honest. If a tool depends on session state, auth
  result, request headers, or progress reporting, you can see that dependency in
  the function body immediately. That keeps the runtime easier to debug and
  easier to reason about when the request crosses transport boundaries or moves
  into background-task execution.

  ## Convenience Helpers

  FastestMCP exposes a few narrow convenience helpers for nested runtime code:

  ```elixir
  FastestMCP.add_tool(server, "explicit", fn _arguments, ctx ->
    request = FastestMCP.Context.request_context(ctx)

    %{
      request_id: request.request_id,
      client_id: FastestMCP.Context.client_id(ctx),
      path: request.path
    }
  end)
  ```

  For nested helpers where passing `ctx` through every layer is noisy:

  ```elixir
  defmodule MyApp.ReleaseHelpers do
    def current_request_summary do
      ctx = FastestMCP.Context.current!()
      request = FastestMCP.Context.request_context(ctx)

      %{request_id: request.request_id, transport: request.transport}
    end
  end
  ```

  The recommended default is still explicit handler `ctx`. `current/0` and
  `current!/0` are convenience helpers for nested runtime code, not a hidden
  global programming model.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Elicitation
  alias FastestMCP.EventBus
  alias FastestMCP.Error
  alias FastestMCP.HTTPRequest
  alias FastestMCP.JSONValue
  alias FastestMCP.OperationPipeline
  alias FastestMCP.PeerTask
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Sampling, as: SamplingProtocol
  alias FastestMCP.RequestContext
  alias FastestMCP.SamplingTool
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.TTLStore

  require Logger

  @excluded_http_headers ["accept", "content-length", "content-type", "host"]
  @visibility_rules_key {:fastest_mcp, :visibility_rules}
  @logging_levels [
    "debug",
    "info",
    "notice",
    "warning",
    "error",
    "critical",
    "alert",
    "emergency"
  ]
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

  defstruct [
    :server_name,
    :server,
    :session_id,
    :request_id,
    :transport,
    :state_scope,
    :negotiated_protocol_version,
    :event_bus,
    :task_store,
    :principal,
    auth: %{},
    capabilities: [],
    verified_audiences: [],
    verified_scopes: [],
    client_capabilities: %{},
    server_capabilities: %{},
    lifespan_context: %{},
    dependencies: %{},
    request_metadata: %{},
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
          event_bus: pid() | atom(),
          task_store: pid() | atom() | nil,
          principal: any(),
          auth: map(),
          capabilities: [any()],
          verified_audiences: [String.t()],
          verified_scopes: [String.t()],
          client_capabilities: map(),
          server_capabilities: map(),
          lifespan_context: map(),
          dependencies: map(),
          request_metadata: map(),
          task_metadata: map()
        }

  @doc "Builds the value managed by this module from runtime state and options."
  def build(server_name, opts \\ []) do
    request_id = "req-" <> Integer.to_string(System.unique_integer([:positive]))
    transport = Keyword.get(opts, :transport, :in_process)
    request_metadata = Map.new(Keyword.get(opts, :request_metadata, %{}))
    state_scope = context_state_scope(opts, request_metadata)
    session_id = context_session_id(opts, state_scope)
    event_bus = Keyword.get(opts, :event_bus, EventBus)
    server = Keyword.get(opts, :server)
    task_store = Keyword.get(opts, :task_store)
    session_supervisor = Keyword.get(opts, :session_supervisor, SessionSupervisor)
    terminated_session_store = Keyword.get(opts, :terminated_session_store)
    principal = Keyword.get(opts, :principal)
    auth = normalize_map(Keyword.get(opts, :auth, %{}))
    capabilities = normalize_capabilities(Keyword.get(opts, :capabilities, []))
    verified_audiences = List.wrap(Keyword.get(opts, :verified_audiences, []))
    verified_scopes = List.wrap(Keyword.get(opts, :verified_scopes, []))
    client_capabilities = normalize_map(Keyword.get(opts, :client_capabilities, %{}))
    server_capabilities = normalize_map(Keyword.get(opts, :server_capabilities, %{}))
    negotiated_protocol_version = Keyword.get(opts, :negotiated_protocol_version)
    lifespan_context = Map.new(Keyword.get(opts, :lifespan_context, %{}))
    dependencies = normalize_dependencies(Keyword.get(opts, :dependencies, %{}))
    task_metadata = Map.new(Keyword.get(opts, :task_metadata, %{}))

    context = %__MODULE__{
      server_name: to_string(server_name),
      server: server,
      session_id: session_id,
      request_id: request_id,
      transport: transport,
      state_scope: state_scope,
      negotiated_protocol_version: negotiated_protocol_version,
      event_bus: event_bus,
      task_store: task_store,
      principal: principal,
      auth: auth,
      capabilities: capabilities,
      verified_audiences: verified_audiences,
      verified_scopes: verified_scopes,
      client_capabilities: client_capabilities,
      server_capabilities: server_capabilities,
      lifespan_context: lifespan_context,
      dependencies: dependencies,
      request_metadata: request_metadata,
      task_metadata: task_metadata
    }

    if state_scope == :request do
      {:ok, context}
    else
      with :ok <-
             ensure_session_not_terminated(
               terminated_session_store,
               transport,
               session_id,
               request_metadata
             ) do
        case SessionSupervisor.ensure_session(session_supervisor, server_name, session_id) do
          {:ok, _pid} ->
            {:ok, context}

          {:error, :overloaded} ->
            {:error,
             %Error{
               code: :overloaded,
               message: "session was rejected because the server is at session capacity",
               details: %{resource: :sessions, retry_after_seconds: 1}
             }}

          {:error, reason} ->
            {:error,
             %Error{
               code: :internal_error,
               message: "failed to create session context",
               details: %{reason: inspect(reason)}
             }}
        end
      end
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
    Process.put({__MODULE__, context.request_id, key}, value)
    :ok
  end

  @doc "Reads request-scoped state from the context."
  def get_request_state(%__MODULE__{} = context, key, default \\ nil) do
    Process.get({__MODULE__, context.request_id, key}, default)
  end

  @doc "Deletes one request-scoped value from the context."
  def delete_request_state(%__MODULE__{} = context, key) do
    Process.delete({__MODULE__, context.request_id, key})
    :ok
  end

  @doc "Builds a new server definition."
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
      path: request_metadata_value(context, :path),
      query_params: request_metadata_value(context, :query_params) || %{},
      headers: request_metadata_headers(context),
      meta: request_context_meta(context)
    }
  end

  @doc """
  Returns the authenticated client identifier when one is available.

  FastestMCP derives this from normalized auth or principal data rather than
  exposing a second mutable field on the context struct.
  """
  def client_id(%__MODULE__{} = context) do
    auth_value(context, :client_id) ||
      auth_value(context, :clientId) ||
      principal_value(context, :client_id) ||
      principal_value(context, :clientId) ||
      principal_value(context, :sub) ||
      client_info_name(context)
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
    cache_key = {:dependency, key}

    case get_request_state(context, cache_key, :__missing__) do
      :__missing__ ->
        resolver = Map.fetch!(context.dependencies, key)
        {value, cleanup} = resolve_dependency(resolver, context, key)
        :ok = put_request_state(context, cache_key, value)
        maybe_register_dependency_cleanup(context, value, cleanup)
        value

      value ->
        value
    end
  rescue
    _error in KeyError ->
      raise ArgumentError,
            "unknown dependency #{inspect(name)} for server #{inspect(context.server_name)}"
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
        auth: normalize_map(result.auth),
        capabilities: normalize_capabilities(result.capabilities),
        verified_audiences: audiences,
        verified_scopes: scopes
    }
  end

  @doc "Builds a progress helper for this context."
  def progress(%__MODULE__{} = context) do
    FastestMCP.Progress.new(context)
  end

  @doc "Emits a log event from this context."
  def log(%__MODULE__{} = context, level, data, opts \\ []) do
    level = normalize_log_level(level)

    result = Session.log(context.server_name, context.session_id, level, data, opts)

    if result == :ok do
      emit(
        context,
        [:log, :message],
        %{count: 1},
        %{
          level: level,
          logger: Keyword.get(opts, :logger),
          data: data
        }
      )
    end

    result
  end

  @doc "Sends a raw MCP notification to the connected client session stream."
  def send_notification(context, method, params \\ %{})

  def send_notification(%__MODULE__{} = context, method, params)
      when is_binary(method) and (is_map(params) or is_nil(params)) do
    cond do
      MapSet.member?(@reserved_notification_methods, method) ->
        {:error, :reserved_method}

      is_nil(params) ->
        Session.send_envelope(
          context.server_name,
          context.session_id,
          %{"jsonrpc" => "2.0", "method" => method},
          session_delivery_opts(context, queue: true)
        )

      true ->
        Session.send_notification(
          context.server_name,
          context.session_id,
          method,
          params,
          session_delivery_opts(context, queue: true)
        )
    end
  end

  def send_notification(%__MODULE__{} = context, %{} = notification, _params) do
    with {:ok, notification} <- normalize_extension_notification(notification),
         false <- MapSet.member?(@reserved_notification_methods, notification["method"]) do
      Session.send_envelope(
        context.server_name,
        context.session_id,
        notification,
        session_delivery_opts(context, queue: true)
      )
    else
      true -> {:error, :reserved_method}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Emits a debug log event from this context."
  def debug(%__MODULE__{} = context, data, opts \\ []), do: log(context, :debug, data, opts)

  @doc "Emits an info log event from this context."
  def info(%__MODULE__{} = context, data, opts \\ []), do: log(context, :info, data, opts)

  @doc "Emits a warning log event from this context."
  def warning(%__MODULE__{} = context, data, opts \\ []), do: log(context, :warning, data, opts)

  @doc "Emits an error log event from this context."
  def error(%__MODULE__{} = context, data, opts \\ []), do: log(context, :error, data, opts)

  @doc "Runs a sampling request from this context."
  def sample(context, prompt_or_messages, opts \\ [])

  def sample(%__MODULE__{} = context, prompt, opts) when is_binary(prompt) do
    messages = [
      %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => prompt
        }
      }
    ]

    sample(context, messages, opts)
  end

  def sample(%__MODULE__{} = context, messages, opts) when is_list(messages) do
    messages = SamplingProtocol.validate_messages!(messages)
    tools = sampling_tool_definitions(Keyword.get(opts, :tools))
    include_context = normalize_sampling_include_context(Keyword.get(opts, :include_context))
    validate_sampling_capabilities!(context, tools, include_context)
    validate_peer_task_capability!(context, opts, ["sampling", "createMessage"])

    params =
      %{
        "messages" => messages,
        "maxTokens" => Keyword.get(opts, :max_tokens, 100)
      }
      |> maybe_put_map("systemPrompt", Keyword.get(opts, :system_prompt))
      |> maybe_put_map("temperature", Keyword.get(opts, :temperature))
      |> maybe_put_map("stopSequences", Keyword.get(opts, :stop_sequences))
      |> maybe_put_map("_meta", Keyword.get(opts, :meta))
      |> maybe_put_map("metadata", Keyword.get(opts, :metadata))
      |> maybe_put_map("modelPreferences", Keyword.get(opts, :model_preferences))
      |> maybe_put_map("includeContext", include_context)
      |> maybe_put_map("tools", tools)
      |> maybe_put_sampling_tool_choice(tools, Keyword.get(opts, :tool_choice, :auto))
      |> maybe_put_task_request(opts)

    cond do
      is_background_task(context) ->
        case task_store(context) do
          nil ->
            raise RuntimeError, "background task context is missing its task store"

          store ->
            case BackgroundTaskStore.sample(
                   store,
                   task_id(context),
                   params,
                   Keyword.get(opts, :timeout_ms, 60_000)
                 ) do
              {:ok, result} ->
                validate_sampling_result!(result, tools, opts)

              {:error, %Error{} = error} ->
                raise error

              {:error, :not_found} ->
                raise Error,
                  code: :not_found,
                  message: "unknown background task #{inspect(task_id(context))}"
            end
        end

      true ->
        result =
          send_client_request(
            context,
            "sampling/createMessage",
            params,
            Keyword.get(opts, :timeout_ms, 60_000),
            opts
          )

        result = validate_sampling_result!(result, tools, opts)
        normalize_peer_task_or_result(context, result, :sampling, "sampling/createMessage")
    end
  end

  @doc "Requests the current filesystem roots from the connected client."
  def list_roots(%__MODULE__{} = context, opts \\ []) do
    require_client_capability!(
      context,
      ["roots"],
      "connected client did not declare roots support"
    )

    if not Keyword.get(opts, :refresh, false) do
      case Session.cached_roots(context.server_name, context.session_id) do
        roots when is_list(roots) -> roots
        _other -> request_and_cache_roots(context, opts)
      end
    else
      request_and_cache_roots(context, opts)
    end
  end

  @doc "Returns the roots cached for this session, or nil before the first successful request."
  def cached_roots(%__MODULE__{} = context) do
    Session.cached_roots(context.server_name, context.session_id)
  end

  @doc "Lists tasks owned by the connected peer for this session."
  def list_peer_tasks(%__MODULE__{} = context, opts \\ []) do
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

  @doc "Sends an MCP ping request to the connected client."
  def ping_peer(%__MODULE__{} = context, opts \\ []) do
    case send_client_request(
           context,
           "ping",
           %{},
           Keyword.get(opts, :timeout_ms, 60_000),
           opts
         ) do
      %{} = result when map_size(result) == 0 -> :ok
      %{} -> {:error, :invalid_ping_result}
    end
  end

  @doc "Runs a URL-mode elicitation with the connected client."
  def elicit_url(%__MODULE__{} = context, message, url_or_builder, opts \\ []) do
    require_client_capability!(
      context,
      ["elicitation", "url"],
      "connected client did not declare elicitation.url support"
    )

    validate_peer_task_capability!(context, opts, ["elicitation", "create"])

    elicitation = build_and_register_url_elicitation!(context, message, url_or_builder, opts)

    result =
      send_client_request(
        context,
        "elicitation/create",
        elicitation
        |> FastestMCP.Elicitation.URL.to_params()
        |> maybe_put_task_request(opts),
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

  @doc "Registers URL elicitation descriptors and raises the standard -32042 error."
  def require_url_elicitation!(%__MODULE__{} = context, message, url_or_builder, opts \\ []) do
    require_client_capability!(
      context,
      ["elicitation", "url"],
      "connected client did not declare elicitation.url support"
    )

    elicitation = build_and_register_url_elicitation!(context, message, url_or_builder, opts)
    raise FastestMCP.Elicitation.URL.required_error([elicitation])
  end

  @doc "Returns the current access token available on the context."
  def access_token(%__MODULE__{} = context) do
    request_access_token(context) || auth_access_token(context)
  end

  @doc "Lists visible resources using the current request context."
  def list_resources(%__MODULE__{} = context) do
    OperationPipeline.list_resources(context.server_name, inherited_operation_opts(context))
  end

  @doc "Reads a resource using the current request context."
  def read_resource(%__MODULE__{} = context, uri) do
    OperationPipeline.read_resource(context.server_name, uri, inherited_operation_opts(context))
  end

  @doc "Notifies subscribed sessions that one concrete resource URI changed."
  def notify_resource_updated(%__MODULE__{} = context, uri) do
    FastestMCP.notify_resource_updated(context.server_name, uri)
  end

  @doc "Lists visible prompts using the current request context."
  def list_prompts(%__MODULE__{} = context) do
    OperationPipeline.list_prompts(context.server_name, inherited_operation_opts(context))
  end

  @doc "Renders a prompt using the current request context."
  def render_prompt(%__MODULE__{} = context, name, arguments \\ %{}) do
    OperationPipeline.render_prompt(
      context.server_name,
      name,
      arguments,
      inherited_operation_opts(context)
    )
  end

  @doc "Enables matching components for the current session only."
  def enable_components(%__MODULE__{} = context, opts \\ []) do
    update_visibility_rules(context, :enable, opts)
  end

  @doc "Disables matching components for the current session only."
  def disable_components(%__MODULE__{} = context, opts \\ []) do
    update_visibility_rules(context, :disable, opts)
  end

  @doc "Clears all session visibility rules."
  def reset_visibility(%__MODULE__{} = context) do
    before = visible_component_sets(context)
    :ok = delete_state(context, @visibility_rules_key)
    emit_visibility_change(context, before, visible_component_sets(context))
    :ok
  end

  @doc "Returns the immutable HTTP request snapshot for this context."
  def http_request(%__MODULE__{} = context) do
    method = request_metadata_value(context, :method)
    path = request_metadata_value(context, :path)
    query_params = request_metadata_value(context, :query_params) || %{}
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

    if Keyword.get(opts, :include_all, false) do
      headers
    else
      Map.drop(headers, @excluded_http_headers)
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
        task_metadata: task_metadata
    }
  end

  @doc "Returns whether the context belongs to background-task execution."
  def is_background_task(%__MODULE__{} = context), do: not is_nil(task_id(context))
  @doc "Returns whether the context belongs to background-task execution."
  def background_task?(%__MODULE__{} = context), do: is_background_task(context)

  @doc "Returns the current background-task id, if any."
  def task_id(%__MODULE__{} = context) do
    Map.get(context.task_metadata, :task_id, Map.get(context.task_metadata, "task_id"))
  end

  @doc "Returns the original request id that created the background task, if any."
  def origin_request_id(%__MODULE__{} = context) do
    Map.get(
      context.task_metadata,
      :origin_request_id,
      Map.get(context.task_metadata, "origin_request_id")
    )
  end

  @doc "Records a progress update."
  def report_progress(%__MODULE__{} = context, current, total \\ nil, message \\ nil) do
    progress =
      %{}
      |> maybe_put(:current, current)
      |> maybe_put(:total, total)
      |> maybe_put(:message, message)
      |> Map.put(:reported_at, System.system_time(:millisecond))

    case {task_store(context), task_id(context)} do
      {store, task_id} when not is_nil(store) and is_binary(task_id) and task_id != "" ->
        BackgroundTaskStore.report_progress(store, task_id, progress)

      _other ->
        :ok
    end

    delivery =
      case progress_token(context) do
        nil ->
          {:error, :missing_progress_token}

        _token ->
          Session.report_progress(
            context.server_name,
            context.session_id,
            protocol_request_id(context),
            %{
              "progress" => current
            }
            |> maybe_put_map("total", total)
            |> maybe_put_map("message", message)
          )
      end

    emit(context, [:task, :progress], progress, %{task_id: task_id(context)})
    delivery
  end

  @doc "Requests interactive input for a background task."
  def elicit(%__MODULE__{} = context, message, response_type, opts \\ []) do
    request = Elicitation.request(message, response_type, opts)

    cond do
      is_background_task(context) ->
        case task_store(context) do
          nil ->
            raise RuntimeError, "background task context is missing its task store"

          store ->
            case BackgroundTaskStore.elicit(
                   store,
                   task_id(context),
                   request,
                   request.timeout_ms
                 ) do
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

      has_client_bridge?(context) ->
        require_client_capability!(
          context,
          ["elicitation", "form"],
          "connected client did not declare elicitation.form support"
        )

        validate_peer_task_capability!(context, opts, ["elicitation", "create"])

        response =
          send_client_request(
            context,
            "elicitation/create",
            %{
              "mode" => "form",
              "message" => request.message,
              "requestedSchema" => request.requested_schema
            }
            |> maybe_put_task_request(opts),
            request.timeout_ms,
            opts
          )

        case normalize_peer_task_or_result(
               context,
               response,
               :elicitation,
               "elicitation/create"
             ) do
          %PeerTask{} = task ->
            task

          %{} = result ->
            case Elicitation.resolve(
                   request,
                   Map.get(result, "action"),
                   Map.get(result, "content")
                 ) do
              {:ok, resolved} -> resolved
              {:error, %Error{} = error} -> raise error
            end
        end

      true ->
        raise RuntimeError,
              "elicitation requires a background task or an initialized deliverable MCP session"
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
    Process.get()
    |> Enum.each(fn
      {{__MODULE__, request_id, _key} = dictionary_key, _value}
      when request_id == context.request_id ->
        Process.delete(dictionary_key)

      _other ->
        :ok
    end)
  end

  defp restore_current(nil), do: Process.delete({__MODULE__, :current_context})

  defp restore_current(%__MODULE__{} = context),
    do: Process.put({__MODULE__, :current_context}, context)

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  defp normalize_dependencies(dependencies) when is_list(dependencies) or is_map(dependencies) do
    dependencies
    |> Enum.into(%{}, fn {name, resolver} -> {normalize_dependency_name(name), resolver} end)
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities), do: capabilities
  defp normalize_capabilities(nil), do: []
  defp normalize_capabilities(capability), do: List.wrap(capability)

  defp context_state_scope(opts, _request_metadata) do
    requested = Keyword.get(opts, :state_scope, :session)

    if requested in [:request, :session] do
      requested
    else
      raise ArgumentError, "state_scope must be :request or :session, got #{inspect(requested)}"
    end
  end

  defp context_session_id(opts, :request) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, nil} -> nil
      {:ok, session_id} -> normalize_session_id!(session_id, :request)
      :error -> nil
    end
  end

  defp context_session_id(opts, :session) do
    session_id =
      case Keyword.get(opts, :session_id) do
        nil -> generate_session_id()
        session_id -> to_string(session_id)
      end

    normalize_session_id!(session_id, :session)
  end

  defp normalize_session_id!(session_id, scope) do
    session_id = to_string(session_id)

    if session_id == "" do
      raise ArgumentError, "session_id must not be empty for #{scope}-scoped context"
    else
      session_id
    end
  end

  defp ensure_session_not_terminated(nil, _transport, _session_id, _request_metadata), do: :ok

  defp ensure_session_not_terminated(store, :streamable_http, session_id, request_metadata) do
    if explicit_http_session?(request_metadata) do
      case TTLStore.get(store, session_id) do
        {:ok, true} ->
          {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp ensure_session_not_terminated(_store, _transport, _session_id, _request_metadata), do: :ok

  defp explicit_http_session?(request_metadata) do
    Map.get(
      request_metadata,
      :session_id_provided,
      Map.get(request_metadata, "session_id_provided", false)
    )
  end

  defp request_task_store(%__MODULE__{} = context) do
    Map.get(context.task_metadata, :task_store, Map.get(context.task_metadata, "task_store"))
  end

  defp has_client_bridge?(%__MODULE__{} = context) do
    is_binary(context.session_id) and
      Session.deliverable?(context.server_name, context.session_id)
  end

  defp progress_token(%__MODULE__{} = context) do
    request_metadata_value(context, :progress_token)
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
    |> Keyword.put_new(:sink_ref, request_metadata_value(context, :session_sink_ref))
    |> Keyword.put_new(:origin_request_id, protocol_request_id(context))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp protocol_request_id(%__MODULE__{} = context) do
    request_metadata_value(context, :jsonrpc_request_id) || context.request_id
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
          |> maybe_put_map("ttl", Keyword.get(task_opts, :ttl))

        Map.put(params, "task", task)

      other ->
        raise ArgumentError,
              "task must be true, false, or keyword options, got: #{inspect(other)}"
    end
  end

  defp request_and_cache_roots(context, opts) do
    result =
      send_client_request(
        context,
        "roots/list",
        %{},
        Keyword.get(opts, :timeout_ms, 60_000),
        opts
      )

    roots = Map.fetch!(result, "roots")

    case Session.cache_roots(context.server_name, context.session_id, roots) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        raise Error,
          code: :bad_request,
          message: "invalid roots/list result",
          details: %{reason: inspect(reason)}
    end
  end

  defp require_client_capability!(%__MODULE__{} = context, path, message) do
    if Protocol.capability?(context.client_capabilities, path) do
      :ok
    else
      raise Error, code: :method_not_found, message: message
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

    FastestMCP.Elicitation.URL.new!(message, url_or_builder,
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

  defp request_metadata_value(%__MODULE__{} = context, key) do
    Map.get(context.request_metadata, key, Map.get(context.request_metadata, Atom.to_string(key)))
  end

  defp inherited_operation_opts(%__MODULE__{} = context) do
    [
      session_id: context.session_id,
      transport: context.transport,
      request_metadata: context.request_metadata,
      principal: context.principal,
      auth: context.auth,
      capabilities: context.capabilities,
      verified_audiences: context.verified_audiences,
      verified_scopes: context.verified_scopes,
      task_metadata: context.task_metadata
    ]
  end

  defp update_visibility_rules(%__MODULE__{} = context, action, opts) do
    before = visible_component_sets(context)
    rules = get_state(context, @visibility_rules_key, [])
    next_rules = List.wrap(rules) ++ ComponentVisibility.normalize_rules(action, opts)
    :ok = set_state(context, @visibility_rules_key, next_rules)
    emit_visibility_change(context, before, visible_component_sets(context))
    :ok
  end

  defp visible_component_sets(%__MODULE__{} = context) do
    FastestMCP.OperationPipeline.visible_component_sets(
      context.server_name,
      inherited_operation_opts(context)
    )
  end

  defp emit_visibility_change(_context, before_sets, after_sets)
       when before_sets == after_sets,
       do: :ok

  defp emit_visibility_change(%__MODULE__{} = context, before_sets, after_sets) do
    families =
      [:tools, :resources, :prompts]
      |> Enum.filter(&(Map.get(before_sets, &1, []) != Map.get(after_sets, &1, [])))

    if families != [] do
      emit(
        context,
        [:components, :changed],
        %{count: length(families)},
        %{families: families, session_id: context.session_id}
      )
    end
  end

  defp request_metadata_headers(%__MODULE__{} = context) do
    context
    |> request_metadata_value(:headers)
    |> normalize_headers()
  end

  defp request_context_meta(%__MODULE__{} = context) do
    meta =
      context.request_metadata
      |> Map.new()
      |> Map.delete(:headers)
      |> Map.delete("headers")
      |> Map.delete(:path)
      |> Map.delete("path")
      |> Map.delete(:query_params)
      |> Map.delete("query_params")
      |> Map.new(fn {key, value} ->
        normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
        {normalized_key, value}
      end)

    case request_client_info(context) do
      %{} = client_info ->
        Map.put_new(meta, "clientInfo", client_info)

      _other ->
        meta
    end
  end

  defp request_access_token(%__MODULE__{} = context) do
    headers = request_metadata_headers(context)

    case Map.get(headers, "authorization", Map.get(headers, :authorization)) do
      "Bearer " <> token when token != "" -> token
      _other -> nil
    end
  end

  defp auth_access_token(%__MODULE__{} = context) do
    Map.get(context.auth, :token, Map.get(context.auth, "token"))
  end

  defp auth_value(%__MODULE__{} = context, key) do
    Map.get(context.auth, key, Map.get(context.auth, to_string(key)))
  end

  defp client_info_name(%__MODULE__{} = context) do
    case request_client_info(context) do
      %{} = client_info ->
        Map.get(client_info, "name", Map.get(client_info, :name))

      _other ->
        nil
    end
  end

  defp request_client_info(%__MODULE__{} = context) do
    request_metadata_value(context, :clientInfo) ||
      request_metadata_value(context, :client_info) ||
      if(context.state_scope == :session,
        do: Session.client_info(context.server_name, context.session_id)
      )
  end

  defp principal_value(%__MODULE__{principal: %{} = principal}, key) do
    Map.get(principal, key, Map.get(principal, to_string(key)))
  end

  defp principal_value(_context, _key), do: nil

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp normalize_log_level(level) when is_atom(level),
    do: level |> Atom.to_string() |> normalize_log_level()

  defp normalize_log_level(level) when is_binary(level) do
    if level in @logging_levels do
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
    cond do
      not sampling_base_capability?(context) ->
        raise Error,
          code: :method_not_found,
          message: "connected client did not declare sampling support"

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

  defp sampling_base_capability?(%__MODULE__{client_capabilities: capabilities}) do
    is_map(Map.get(capabilities, "sampling", Map.get(capabilities, :sampling)))
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

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
