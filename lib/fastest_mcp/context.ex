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

  alias FastestMCP.Auth.Result
  alias FastestMCP.Auth.StateStore
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Elicitation
  alias FastestMCP.EventBus
  alias FastestMCP.Error
  alias FastestMCP.HTTPRequest
  alias FastestMCP.OperationPipeline
  alias FastestMCP.RequestContext
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.TaskWire

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

  defstruct [
    :server_name,
    :server,
    :session_id,
    :request_id,
    :transport,
    :event_bus,
    :task_store,
    :principal,
    auth: %{},
    capabilities: [],
    lifespan_context: %{},
    dependencies: %{},
    request_metadata: %{},
    task_metadata: %{}
  ]

  @type t :: %__MODULE__{
          server_name: String.t(),
          server: FastestMCP.Server.t() | nil,
          session_id: String.t(),
          request_id: String.t(),
          transport: atom(),
          event_bus: pid() | atom(),
          task_store: pid() | atom() | nil,
          principal: any(),
          auth: map(),
          capabilities: [any()],
          lifespan_context: map(),
          dependencies: map(),
          request_metadata: map(),
          task_metadata: map()
        }

  @doc "Builds the value managed by this module from runtime state and options."
  def build(server_name, opts \\ []) do
    session_id = opts[:session_id] || generate_session_id()

    request_id = "req-" <> Integer.to_string(System.unique_integer([:positive]))
    transport = Keyword.get(opts, :transport, :in_process)
    event_bus = Keyword.get(opts, :event_bus, EventBus)
    server = Keyword.get(opts, :server)
    task_store = Keyword.get(opts, :task_store)
    session_supervisor = Keyword.get(opts, :session_supervisor, SessionSupervisor)
    terminated_session_store = Keyword.get(opts, :terminated_session_store)
    principal = Keyword.get(opts, :principal)
    auth = normalize_map(Keyword.get(opts, :auth, %{}))
    capabilities = normalize_capabilities(Keyword.get(opts, :capabilities, []))
    lifespan_context = Map.new(Keyword.get(opts, :lifespan_context, %{}))
    dependencies = normalize_dependencies(Keyword.get(opts, :dependencies, %{}))
    request_metadata = Map.new(Keyword.get(opts, :request_metadata, %{}))
    task_metadata = Map.new(Keyword.get(opts, :task_metadata, %{}))

    with :ok <-
           ensure_session_not_terminated(
             terminated_session_store,
             transport,
             session_id,
             request_metadata
           ) do
      case SessionSupervisor.ensure_session(session_supervisor, server_name, session_id) do
        {:ok, _pid} ->
          {:ok,
           %__MODULE__{
             server_name: to_string(server_name),
             server: server,
             session_id: to_string(session_id),
             request_id: request_id,
             transport: transport,
             event_bus: event_bus,
             task_store: task_store,
             principal: principal,
             auth: auth,
             capabilities: capabilities,
             lifespan_context: lifespan_context,
             dependencies: dependencies,
             request_metadata: request_metadata,
             task_metadata: task_metadata
           }}

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

  @doc "Runs the given function with this context installed as the current request context."
  def with_request(%__MODULE__{} = context, fun) when is_function(fun, 0) do
    previous = current()
    Process.put({__MODULE__, :current_context}, context)

    try do
      fun.()
    after
      run_dependency_cleanups(context)
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
    if Keyword.get(opts, :serializable, true) do
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
        Session.get(context.server_name, context.session_id, key, default)

      value ->
        value
    end
  end

  @doc "Deletes state for the current context."
  def delete_state(%__MODULE__{} = context, key) do
    :ok = delete_request_state(context, {:state, key})
    Session.delete(context.server_name, context.session_id, key)
  end

  @doc "Stores a resolved auth result on the context."
  def put_auth_result(%__MODULE__{} = context, %Result{} = result) do
    %{
      context
      | principal: result.principal,
        auth: normalize_map(result.auth),
        capabilities: normalize_capabilities(result.capabilities)
    }
  end

  @doc "Builds a progress helper for this context."
  def progress(%__MODULE__{} = context) do
    FastestMCP.Progress.new(context)
  end

  @doc "Emits a log event from this context."
  def log(%__MODULE__{} = context, level, data, opts \\ []) do
    level = normalize_log_level(level)

    notification =
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" =>
          %{
            "level" => level,
            "data" => data
          }
          |> maybe_put_map("logger", Keyword.get(opts, :logger))
      }

    send_client_notification(context, notification)

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

  @doc "Sends a raw MCP notification to the connected client session stream."
  def send_notification(context, method, params \\ %{})

  def send_notification(%__MODULE__{} = context, method, params)
      when is_binary(method) and (is_map(params) or is_nil(params)) do
    notification =
      %{
        "jsonrpc" => "2.0",
        "method" => method
      }
      |> maybe_put_map("params", params)

    send_client_notification(context, notification)
  end

  def send_notification(%__MODULE__{} = context, %{} = notification, _params) do
    send_client_notification(context, Map.put_new(notification, "jsonrpc", "2.0"))
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
    params =
      %{
        "messages" => messages,
        "maxTokens" => Keyword.get(opts, :max_tokens, 100)
      }
      |> maybe_put_map("systemPrompt", Keyword.get(opts, :system_prompt))
      |> maybe_put_map("temperature", Keyword.get(opts, :temperature))
      |> maybe_put_map("stopSequences", Keyword.get(opts, :stop_sequences))
      |> maybe_put_map("metadata", Keyword.get(opts, :metadata))
      |> maybe_put_map("modelPreferences", Keyword.get(opts, :model_preferences))
      |> maybe_put_map("includeContext", Keyword.get(opts, :include_context))

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
                result

              {:error, %Error{} = error} ->
                raise error

              {:error, :not_found} ->
                raise Error,
                  code: :not_found,
                  message: "unknown background task #{inspect(task_id(context))}"
            end
        end

      true ->
        send_client_request(
          context,
          "sampling/createMessage",
          params,
          Keyword.get(opts, :timeout_ms, 60_000)
        )
    end
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

    maybe_send_progress_notification(context, progress)

    emit(context, [:task, :progress], progress, %{task_id: task_id(context)})
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
        response =
          send_client_request(
            context,
            "elicitation/create",
            %{
              "message" => request.message,
              "requestedSchema" => request.requested_schema
            },
            request.timeout_ms
          )

        case Elicitation.resolve(
               request,
               Map.get(response, "action"),
               Map.get(response, "content")
             ) do
          {:ok, result} ->
            result

          {:error, %Error{} = error} ->
            raise error
        end

      true ->
        raise RuntimeError,
              "elicitation is only supported in background task context or an active streamable HTTP request"
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

  defp ensure_session_not_terminated(nil, _transport, _session_id, _request_metadata), do: :ok

  defp ensure_session_not_terminated(store, :streamable_http, session_id, request_metadata) do
    if explicit_http_session?(request_metadata) do
      case StateStore.get(store, session_id) do
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
    is_pid(client_stream_pid(context)) and not is_nil(client_request_store(context))
  end

  defp client_stream_pid(%__MODULE__{} = context) do
    request_metadata_value(context, :client_stream_pid)
  end

  defp client_request_store(%__MODULE__{} = context) do
    request_metadata_value(context, :client_request_store)
  end

  defp progress_token(%__MODULE__{} = context) do
    request_metadata_value(context, :progress_token)
  end

  defp maybe_send_progress_notification(%__MODULE__{} = context, progress) do
    case {client_stream_pid(context), progress_token(context)} do
      {pid, token} when is_pid(pid) and not is_nil(token) ->
        params =
          %{
            "progressToken" => token,
            "progress" => Map.get(progress, :current, Map.get(progress, "current", 0))
          }
          |> maybe_put_map("total", Map.get(progress, :total, Map.get(progress, "total")))
          |> maybe_put_map(
            "message",
            Map.get(progress, :message, Map.get(progress, "message"))
          )

        send(
          pid,
          {:client_bridge_notification,
           %{
             "jsonrpc" => "2.0",
             "method" => "notifications/progress",
             "params" => params
           }}
        )

      _other ->
        :ok
    end
  end

  defp send_client_notification(%__MODULE__{} = context, message) do
    case client_stream_pid(context) do
      pid when is_pid(pid) ->
        send(pid, {:client_bridge_notification, message})
        :ok

      _other ->
        :ok
    end
  end

  defp send_client_request(%__MODULE__{} = context, method, params, timeout_ms) do
    stream_pid =
      case client_stream_pid(context) do
        pid when is_pid(pid) ->
          pid

        _other ->
          raise RuntimeError,
                "#{method} requires an active streamable HTTP client request context"
      end

    store =
      case client_request_store(context) do
        pid when is_pid(pid) ->
          pid

        _other ->
          raise RuntimeError,
                "#{method} requires an active streamable HTTP client request store"
      end

    request_id = "srv-" <> Integer.to_string(System.unique_integer([:positive]))

    send(
      stream_pid,
      {:client_bridge_request, self(), request_id,
       client_request_payload(context, request_id, method, params), store, context.session_id,
       timeout_ms}
    )

    receive do
      {:client_bridge_response, ^request_id, {:ok, result}} ->
        result

      {:client_bridge_response, ^request_id, {:error, %Error{} = error}} ->
        raise error

      {:client_bridge_response, ^request_id, {:error, reason}} ->
        raise Error,
          code: :internal_error,
          message: "#{method} failed",
          details: %{reason: inspect(reason)}
    after
      timeout_ms ->
        :ok = StateStore.delete(store, request_id)

        raise Error,
          code: :timeout,
          message: "#{method} timed out",
          details: %{timeout_ms: timeout_ms}
    end
  end

  defp client_request_payload(%__MODULE__{} = context, request_id, method, params) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params
    }

    case task_id(context) do
      task_id when is_binary(task_id) and task_id != "" ->
        TaskWire.attach_related_task_meta(payload, task_id)

      _other ->
        payload
    end
  end

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
      Session.client_info(context.server_name, context.session_id)
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
      try do
        run_dependency_cleanup(cleanup, value, context)
      rescue
        _error -> :ok
      end
    end)
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

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
