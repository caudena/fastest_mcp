defmodule FastestMCP do
  @moduledoc ~S"""
  The high-level API.

  `FastestMCP` is the top of the public surface. Most users start here and stay
  here for day-to-day work:

    * building a `%FastestMCP.Server{}` with the pipeline-style builder API
    * starting and stopping a running server
    * dispatching in-process MCP operations
    * exposing HTTP or stdio transports
    * working with background tasks
    * preparing sampling tools

  Under that facade, the runtime is composed of a few lower-level pieces:

    * `FastestMCP.Server` - immutable server definitions
    * `FastestMCP.ServerModule` - module-owned server API with generated OTP helpers
    * `FastestMCP.Context` - explicit request, session, auth, and task context
    * `FastestMCP.RequestContext` - stable request snapshot derived from `FastestMCP.Context`
    * `FastestMCP.Client` - connected MCP client
    * `FastestMCP.Tools.Result` - explicit tool result helper
    * `FastestMCP.Prompts.Message` and `FastestMCP.Prompts.Result` - explicit prompt result helpers
    * `FastestMCP.Resources.Content`, `FastestMCP.Resources.Result`, and the
      `FastestMCP.Resources.*` helper modules - explicit resource result helpers,
      including file, HTTP, and directory-backed resources
    * the shared operation pipeline used by local dispatch

  The design goal is simple: keep the public API small while keeping the runtime
  explicitly OTP-shaped.

  ## Examples

  Build a small server definition:

  ```elixir
  server =
    FastestMCP.server("docs")
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
  ```

  Start it and call it in process:

  ```elixir
  {:ok, _pid} = FastestMCP.start_server(server)
  42 = FastestMCP.call_tool("docs", "sum", %{"a" => 20, "b" => 22})
  :ok = FastestMCP.stop_server("docs")
  ```

  Expose the same runtime over HTTP:

  ```elixir
  plug = FastestMCP.http_app("docs", allowed_hosts: :localhost)
  child = {Bandit, plug: plug, port: 4100}
  ```

  Prepare local tools for sampling:

  ```elixir
  tools = FastestMCP.prepare_sampling_tools("docs")
  ```

  Resolve tool-argument completion values:

  ```elixir
  FastestMCP.complete(
    "docs",
    %{type: "ref/tool", name: "deploy"},
    %{name: "environment", value: "prev"}
  )
  ```

  ## When To Drop Lower

  Use this module when you want the shortest path.

  Drop to `FastestMCP.Server` when you need to work with the immutable server
  struct directly. Drop to `FastestMCP.ServerModule` when the server belongs to
  your application supervision tree. Drop to `FastestMCP.Context` when you are
  inside a handler and need request or session state. Reach for the tool,
  prompt, and resource helper modules when a component needs explicit control
  over result envelopes.
  """

  alias FastestMCP.BackgroundTask
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentManager
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Provider
  alias FastestMCP.Providers.OpenAPI
  alias FastestMCP.Protocol
  alias FastestMCP.Sampling
  alias FastestMCP.Server
  alias FastestMCP.TaskNotificationSupervisor
  alias FastestMCP.TaskOwner
  alias FastestMCP.ServerRuntime

  @doc "Builds a new server definition."
  defdelegate server(name, opts \\ []), to: Server, as: :new
  @doc "Adds a tool component to the current definition."
  defdelegate add_tool(server, name, handler, opts \\ []), to: Server
  @doc "Adds a resource component to the current definition."
  defdelegate add_resource(server, uri, handler, opts \\ []), to: Server
  @doc "Adds a resource-template component to the current definition."
  defdelegate add_resource_template(server, uri_template, handler, opts \\ []), to: Server
  @doc "Adds a prompt component to the current definition."
  defdelegate add_prompt(server, name, handler, opts \\ []), to: Server
  @doc "Adds an HTTP route to the current definition."
  defdelegate add_http_route(server, method, path, handler), to: Server
  @doc "Registers a dependency resolver on the current definition."
  defdelegate add_dependency(server, name, resolver), to: Server
  @doc "Adds middleware to the current definition."
  defdelegate add_middleware(server, middleware), to: Server
  @doc "Adds a transform to the current definition."
  defdelegate add_transform(server, transform), to: Server
  @doc "Adds a provider to the current definition."
  defdelegate add_provider(server, provider), to: Server
  @doc "Mounts another server or provider-backed definition."
  defdelegate mount(server, mounted_server, opts \\ []), to: Server
  @doc "Adds a transform to a provider wrapper."
  defdelegate add_provider_transform(provider, transform), to: Provider, as: :add_transform

  @doc "Builds an OpenAPI-backed provider from a loaded specification."
  def from_openapi(openapi_spec, opts \\ []) when is_map(openapi_spec) and is_list(opts) do
    provider = OpenAPI.new(Keyword.put(opts, :openapi_spec, openapi_spec))
    server_name = Keyword.get(opts, :name, provider.name)

    server(server_name)
    |> add_provider(provider)
  end

  @doc "Normalizes sampling-tool definitions for later sampling calls."
  def prepare_sampling_tools(server_or_tools, opts \\ []) do
    Sampling.prepare_tools(server_or_tools, opts)
  end

  @doc "Returns the current MCP protocol version."
  def current_protocol_version, do: Protocol.current_version()

  @doc "Fetches the live component manager for a running server."
  def component_manager(server_name) do
    case ComponentManager.fetch(server_name) do
      {:ok, manager} ->
        manager

      {:error, :not_found} ->
        raise Error, code: :not_found, message: "unknown server #{inspect(server_name)}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to fetch component manager",
          details: %{server_name: inspect(server_name), reason: inspect(reason)}
    end
  end

  @doc "Adds auth configuration to the current definition."
  def add_auth(%Server{} = server, provider_or_auth, opts \\ []) do
    Server.add_auth(server, provider_or_auth, opts)
  end

  @doc "Adds lifespan hooks to the current definition."
  def add_lifespan(%Server{} = server, lifespan) do
    Server.add_lifespan(server, lifespan)
  end

  def add_lifespan(%Server{} = server, enter, exit) do
    Server.add_lifespan(server, enter, exit)
  end

  @doc "Starts a server runtime."
  def start_server(server_or_module, opts \\ [])

  def start_server(%Server{} = server, opts) do
    ServerRuntime.start(server, opts)
  end

  def start_server(module, opts) when is_atom(module) and is_list(opts) do
    if FastestMCP.ServerModule.server_module?(module) do
      DynamicSupervisor.start_child(
        FastestMCP.ServerSupervisor,
        module.child_spec(opts)
      )
    else
      raise ArgumentError,
            "#{inspect(module)} is not a FastestMCP server module. Use `use FastestMCP.ServerModule` and implement server/1."
    end
  end

  @doc "Stops a running server runtime."
  def stop_server(server_name) do
    ServerRuntime.stop(server_name)
  end

  @doc "Lists visible tools."
  def list_tools(server_name, opts \\ []) do
    OperationPipeline.list_tools(server_name, opts)
  end

  @doc "Lists visible resources."
  def list_resources(server_name, opts \\ []) do
    OperationPipeline.list_resources(server_name, opts)
  end

  @doc "Lists visible resource templates."
  def list_resource_templates(server_name, opts \\ []) do
    OperationPipeline.list_resource_templates(server_name, opts)
  end

  @doc "Lists visible prompts."
  def list_prompts(server_name, opts \\ []) do
    OperationPipeline.list_prompts(server_name, opts)
  end

  @doc "Enables matching components for all sessions on the running server."
  def enable_components(server_name, opts \\ []) do
    ComponentVisibility.enable(server_name, opts)
  end

  @doc "Disables matching components for all sessions on the running server."
  def disable_components(server_name, opts \\ []) do
    ComponentVisibility.disable(server_name, opts)
  end

  @doc "Clears all server-scoped component visibility rules."
  def reset_component_visibility(server_name) do
    ComponentVisibility.reset(server_name)
  end

  @doc "Runs the MCP initialize handshake."
  def initialize(server_name, params \\ %{}, opts \\ []) do
    OperationPipeline.initialize(server_name, params, opts)
  end

  @doc "Runs a ping request."
  def ping(server_name, params \\ %{}, opts \\ []) do
    OperationPipeline.ping(server_name, params, opts)
  end

  @doc "Calls a tool with the given arguments."
  def call_tool(server_name, name, arguments \\ %{}, opts \\ []) do
    OperationPipeline.call_tool(server_name, name, arguments, opts)
  end

  @doc "Reads a resource by URI."
  def read_resource(server_name, uri, opts \\ []) do
    OperationPipeline.read_resource(server_name, uri, opts)
  end

  @doc "Notifies subscribed sessions that one concrete resource URI changed."
  def notify_resource_updated(server_name, uri) do
    runtime = fetch_runtime!(server_name)

    FastestMCP.EventBus.emit(
      runtime.event_bus,
      server_name,
      [:resources, :updated],
      %{count: 1},
      %{uri: to_string(uri)}
    )
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(server_name, name, arguments \\ %{}, opts \\ []) do
    OperationPipeline.render_prompt(server_name, name, arguments, opts)
  end

  @doc "Resolves completion values for tool arguments, prompt arguments, or resource-template parameters."
  def complete(server_name, ref, argument, opts \\ []) do
    OperationPipeline.complete(server_name, ref, argument, opts)
  end

  @doc "Builds the main HTTP app for a running server."
  def http_app(server_name, opts \\ []) do
    init_opts = FastestMCP.Transport.HTTPApp.init(Keyword.put(opts, :server_name, server_name))
    fn conn -> FastestMCP.Transport.HTTPApp.call(conn, init_opts) end
  end

  @doc "Returns a child spec for the streamable HTTP transport."
  def streamable_http_child_spec(server_name, opts \\ []) do
    FastestMCP.Transport.StreamableHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Returns a child spec for the well-known HTTP transport."
  def well_known_http_child_spec(server_name, opts \\ []) do
    FastestMCP.Transport.WellKnownHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Dispatches one stdio request against a running server."
  def stdio_dispatch(server_name, request, opts \\ []) do
    FastestMCP.Transport.Stdio.dispatch(server_name, request, opts)
  end

  @doc "Fetches background-task state."
  def fetch_task(%BackgroundTask{} = task) do
    fetch_task(task.server_name, task.task_id, background_task_access_opts(task))
  end

  def fetch_task(server_name, task_id, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.fetch(task_store, task_id, opts) do
      {:ok, task} ->
        task

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)
    end
  end

  @doc "Waits for a background task to finish."
  def await_task(%BackgroundTask{} = task, timeout \\ 5_000) do
    await_task(task.server_name, task.task_id, timeout, background_task_access_opts(task))
  end

  def await_task(server_name, task_id, timeout, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.await(task_store, task_id, timeout, opts) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)
    end
  end

  @doc "Returns the normalized result for a background task."
  def task_result(%BackgroundTask{} = task) do
    task_result(task.server_name, task.task_id, background_task_access_opts(task))
  end

  def task_result(server_name, task_id, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.result(task_store, task_id, opts) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)
    end
  end

  @doc "Lists background tasks."
  def list_tasks(server_name, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.list(task_store, opts) do
      {:ok, page} -> page
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise Error, code: :internal_error, message: inspect(reason)
    end
  end

  @doc "Cancels a background task."
  def cancel_task(%BackgroundTask{} = task) do
    cancel_task(task.server_name, task.task_id, background_task_access_opts(task))
  end

  def cancel_task(server_name, task_id, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.cancel(task_store, task_id, opts) do
      {:ok, task} ->
        task

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)
    end
  end

  @doc "Sends input to a background task waiting for user interaction."
  def send_task_input(server_name, task_id, action, content \\ nil, opts \\ []) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.send_input(task_store, task_id, action, content, opts) do
      {:ok, task} ->
        task

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)
    end
  end

  @doc "Starts a subscriber for background-task notifications."
  def subscribe_task_notifications(server_name, session_id, opts \\ []) do
    runtime = fetch_runtime!(server_name)

    TaskNotificationSupervisor.start_subscriber(
      runtime.task_notification_supervisor,
      Keyword.merge(
        [
          server_name: server_name,
          session_id: session_id,
          event_bus: runtime.event_bus,
          task_store: runtime.task_store
        ],
        opts
      )
    )
  end

  @doc "Returns the number of active task-notification subscribers."
  def task_notification_subscriber_count(server_name) do
    server_name
    |> fetch_runtime!()
    |> Map.fetch!(:task_notification_supervisor)
    |> TaskNotificationSupervisor.subscriber_count()
  end

  defp fetch_runtime!(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        runtime

      {:error, :not_found} ->
        raise Error, code: :not_found, message: "unknown server #{inspect(server_name)}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to fetch server runtime",
          details: %{reason: inspect(reason)}
    end
  end

  defp fetch_task_store!(server_name) do
    server_name
    |> fetch_runtime!()
    |> Map.fetch!(:task_store)
  end

  defp normalize_task_access_opts(server_name, opts) do
    owner_fingerprint =
      cond do
        Keyword.has_key?(opts, :owner_fingerprint) ->
          opts[:owner_fingerprint]

        match?(%Context{}, opts[:context]) ->
          TaskOwner.from_context(opts[:context])

        match?(%Context{server_name: ^server_name}, Context.current()) ->
          Context.current() |> TaskOwner.from_context()

        Keyword.has_key?(opts, :principal) or Keyword.has_key?(opts, :auth) ->
          TaskOwner.from_principal_auth(opts[:principal], opts[:auth])

        true ->
          nil
      end

    if Keyword.has_key?(opts, :owner_fingerprint) do
      opts
    else
      Keyword.put(opts, :owner_fingerprint, owner_fingerprint)
    end
  end

  defp background_task_access_opts(%BackgroundTask{owner_fingerprint: owner_fingerprint}) do
    case owner_fingerprint do
      value when is_binary(value) and value != "" -> [owner_fingerprint: value]
      _other -> []
    end
  end

  defp invalid_task_id_error(task_id) do
    %Error{
      code: :invalid_task_id,
      message: "Invalid taskId: #{to_string(task_id)} not found"
    }
  end
end
