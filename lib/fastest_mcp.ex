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
  42 = FastestMCP.call_tool!("docs", "sum", %{"a" => 20, "b" => 22})
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
  FastestMCP.complete!(
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

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.BackgroundTask
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentManager
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Protocol
  alias FastestMCP.Provider
  alias FastestMCP.Providers.OpenAPI
  alias FastestMCP.Registry
  alias FastestMCP.Sampling
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TaskNotificationSupervisor
  alias FastestMCP.TaskOwner
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

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
  @doc "Enables bounded model-visible tool search on the server."
  defdelegate enable_tool_search(server, opts \\ []), to: Server
  @doc "Adds a transform to the current definition."
  defdelegate add_transform(server, transform), to: Server
  @doc "Adds a provider to the current definition."
  defdelegate add_provider(server, provider), to: Server
  @doc "Adds an executable root extension, overriding provider bundles with the same identifier."
  defdelegate add_extension(server, extension), to: Server
  @doc "Mounts another server or provider-backed definition."
  defdelegate mount(server, mounted_server, opts \\ []), to: Server
  @doc "Adds a transform to a provider wrapper."
  defdelegate add_provider_transform(provider, transform), to: Provider, as: :add_transform

  @doc "Builds an OpenAPI-backed provider from a loaded specification."
  def from_openapi(openapi_spec, opts \\ []) when is_map(openapi_spec) and is_list(opts) do
    provider = OpenAPI.new(Keyword.put(opts, :openapi_spec, openapi_spec))
    server_name = Keyword.get(opts, :name, provider.name)

    server(server_name, schema_options: Keyword.get(opts, :schema_options, []))
    |> add_provider(provider)
  end

  @doc "Normalizes sampling-tool definitions for later sampling calls."
  def prepare_sampling_tools(server_or_tools, opts \\ []) do
    Sampling.prepare_tools(server_or_tools, opts)
  end

  @doc "Returns the current MCP protocol version."
  def current_protocol_version, do: Protocol.current_version()

  @doc "Returns supported MCP protocol versions in preference order, newest first."
  def supported_protocol_versions, do: Protocol.supported_versions()

  defp execute_component_manager(server_name) do
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

  @doc "Starts a server runtime, raising on failure."
  def start_server!(server_or_module, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(start_server(server_or_module, opts))

  @doc "Stops a running server runtime."
  def stop_server(server_name) do
    ServerRuntime.stop(server_name)
  end

  @doc "Stops a running server runtime, raising on failure."
  def stop_server!(server_name), do: FastestMCP.OperationResult.unwrap!(stop_server(server_name))

  @doc "Completes a URL elicitation, raising on failure."
  def complete_elicitation!(server_name, elicitation_id, opts),
    do:
      FastestMCP.OperationResult.unwrap!(complete_elicitation(server_name, elicitation_id, opts))

  @doc "Completes one identity-bound URL elicitation for a running server."
  def complete_elicitation(server_name, elicitation_id, opts)
      when is_binary(elicitation_id) and is_list(opts) do
    with {:ok, fingerprint} <- completion_identity_fingerprint(opts),
         {:ok, session_id} <- find_elicitation_session(server_name, elicitation_id) do
      Session.complete_url_elicitation(
        server_name,
        session_id,
        elicitation_id,
        fingerprint
      )
      |> case do
        {:ok, elicitation} ->
          {:ok, elicitation}

        {:error, reason} when reason in [:forbidden, :expired, :already_completed] ->
          {:error, reason}

        {:error, :declined} ->
          {:error, :not_found}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _reason} ->
          {:error, :forbidden}
      end
    end
  end

  defp execute_list_tools(server_name, opts) do
    OperationPipeline.list_tools(server_name, opts)
  end

  defp execute_list_resources(server_name, opts) do
    OperationPipeline.list_resources(server_name, opts)
  end

  defp execute_list_resource_templates(server_name, opts) do
    OperationPipeline.list_resource_templates(server_name, opts)
  end

  defp execute_list_prompts(server_name, opts) do
    OperationPipeline.list_prompts(server_name, opts)
  end

  defp execute_enable_components(server_name, opts) do
    ComponentVisibility.enable(server_name, opts)
  end

  defp execute_disable_components(server_name, opts) do
    ComponentVisibility.disable(server_name, opts)
  end

  defp execute_reset_component_visibility(server_name) do
    ComponentVisibility.reset(server_name)
  end

  defp execute_initialize(server_name, params, opts) do
    OperationPipeline.initialize(server_name, params, opts)
  end

  defp execute_ping(server_name, params, opts) do
    OperationPipeline.ping(server_name, params, opts)
  end

  defp execute_call_tool(server_name, name, arguments, opts) do
    OperationPipeline.call_tool(server_name, name, arguments, opts)
  end

  defp execute_read_resource(server_name, uri, opts) do
    OperationPipeline.read_resource(server_name, uri, opts)
  end

  defp execute_notify_resource_updated(server_name, uri) do
    runtime = fetch_runtime!(server_name)

    FastestMCP.EventBus.emit(
      runtime.event_bus,
      server_name,
      [:resources, :updated],
      %{count: 1},
      %{uri: to_string(uri)}
    )
  end

  defp execute_render_prompt(server_name, name, arguments, opts) do
    OperationPipeline.render_prompt(server_name, name, arguments, opts)
  end

  defp execute_complete(server_name, ref, argument, opts) do
    OperationPipeline.complete(server_name, ref, argument, opts)
  end

  @doc "Builds the main HTTP app for a running server."
  def http_app(server_name, opts \\ []) do
    init_opts = HTTPApp.init(Keyword.put(opts, :server_name, server_name))
    fn conn -> HTTPApp.call(conn, init_opts) end
  end

  @doc "Returns a child spec for the streamable HTTP transport."
  def streamable_http_child_spec(server_name, opts \\ []) do
    StreamableHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Returns a child spec for the well-known HTTP transport."
  def well_known_http_child_spec(server_name, opts \\ []) do
    WellKnownHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Dispatches one stdio request against a running server."
  def stdio_dispatch(server_name, request, opts \\ []) do
    Stdio.dispatch(server_name, request, opts)
  end

  defp execute_fetch_task(%BackgroundTask{} = task) do
    execute_fetch_task(task.server_name, task.task_id, background_task_access_opts(task))
  end

  defp execute_fetch_task(server_name, task_id, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.fetch(task_store, task_id, opts) do
      {:ok, task} ->
        task

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise task_storage_error(:fetch, reason)
    end
  end

  defp execute_await_task(%BackgroundTask{} = task, timeout) do
    execute_await_task(task.server_name, task.task_id, timeout, background_task_access_opts(task))
  end

  defp execute_await_task(server_name, task_id, timeout, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.await(task_store, task_id, timeout, opts) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, reason} ->
        raise task_storage_error(:await, reason)
    end
  end

  defp execute_task_result(%BackgroundTask{} = task) do
    execute_task_result(task.server_name, task.task_id, background_task_access_opts(task))
  end

  defp execute_task_result(server_name, task_id, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.result(task_store, task_id, opts) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, reason} ->
        raise task_storage_error(:result, reason)
    end
  end

  defp execute_list_tasks(server_name, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.list(task_store, opts) do
      {:ok, page} -> page
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise task_storage_error(:list, reason)
    end
  end

  defp execute_cancel_task(%BackgroundTask{} = task) do
    execute_cancel_task(task.server_name, task.task_id, background_task_access_opts(task))
  end

  defp execute_cancel_task(server_name, task_id, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.cancel(task_store, task_id, opts) do
      {:ok, task} ->
        task

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, reason} ->
        raise task_storage_error(:cancel, reason)
    end
  end

  defp execute_update_task(server_name, task_id, input_responses, opts)
       when is_map(input_responses) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.update(task_store, task_id, input_responses, opts) do
      {:ok, task} ->
        task

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, reason} ->
        raise task_storage_error(:update, reason)
    end
  end

  defp execute_send_task_input(server_name, task_id, action, content, opts) do
    task_store = fetch_task_store!(server_name)
    opts = normalize_task_access_opts(server_name, opts)

    case BackgroundTaskStore.send_input(task_store, task_id, action, content, opts) do
      {:ok, task} ->
        task

      {:error, %Error{} = error} ->
        raise error

      {:error, :not_found} ->
        raise invalid_task_id_error(task_id)

      {:error, reason} ->
        raise task_storage_error(:send_input, reason)
    end
  end

  defp execute_subscribe_task_notifications(server_name, session_id, opts) do
    runtime = fetch_runtime!(server_name)

    TaskNotificationSupervisor.start_subscriber(
      runtime.task_notification_supervisor,
      Keyword.merge(
        [
          server_name: server_name,
          session_id: session_id,
          event_bus: runtime.event_bus,
          task_store: runtime.task_store,
          task_supervisor: runtime.stream_task_supervisor
        ],
        opts
      )
    )
  end

  defp execute_task_notification_subscriber_count(server_name) do
    server_name
    |> fetch_runtime!()
    |> Map.fetch!(:task_notification_supervisor)
    |> TaskNotificationSupervisor.subscriber_count()
  end

  defp completion_identity_fingerprint(opts) do
    case Keyword.get(opts, :auth_result) do
      %AuthResult{principal: principal, auth: auth} when not is_nil(principal) ->
        {:ok, Auth.identity_fingerprint(principal, auth)}

      _other ->
        case Keyword.fetch(opts, :principal) do
          {:ok, principal} when not is_nil(principal) ->
            {:ok, Auth.identity_fingerprint(principal, Keyword.get(opts, :auth, %{}))}

          _other ->
            {:error, :forbidden}
        end
    end
  end

  defp find_elicitation_session(server_name, elicitation_id) do
    case Registry.lookup_url_elicitation(server_name, elicitation_id) do
      {:ok, session_id, _session_pid} -> {:ok, session_id}
      {:error, :not_found} -> {:error, :not_found}
    end
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

  defp task_storage_error(operation, reason) do
    %Error{
      code: :internal_error,
      message: "background task storage #{operation} failed",
      details: %{reason: inspect(reason)}
    }
  end

  @doc "Runs `await_task` and returns a tagged result."
  def await_task(task, timeout \\ 5_000),
    do: FastestMCP.OperationResult.capture(fn -> execute_await_task(task, timeout) end, :value)

  @doc "Raising variant of `await_task/2`."
  def await_task!(task, timeout \\ 5_000),
    do: FastestMCP.OperationResult.unwrap!(await_task(task, timeout))

  @doc "Runs `await_task` and returns a tagged result."
  def await_task(server_name, task_id, timeout, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_await_task(server_name, task_id, timeout, opts) end,
        :value
      )

  @doc "Raising variant of `await_task/4`."
  def await_task!(server_name, task_id, timeout, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(await_task(server_name, task_id, timeout, opts))

  @doc "Runs `call_tool` and returns a tagged result."
  def call_tool(server_name, name, arguments \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_call_tool(server_name, name, arguments, opts) end,
        :value
      )

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(server_name, name, arguments \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(call_tool(server_name, name, arguments, opts))

  @doc "Runs `cancel_task` and returns a tagged result."
  def cancel_task(task),
    do: FastestMCP.OperationResult.capture(fn -> execute_cancel_task(task) end, :value)

  @doc "Raising variant of `cancel_task/1`."
  def cancel_task!(task), do: FastestMCP.OperationResult.unwrap!(cancel_task(task))

  @doc "Runs `cancel_task` and returns a tagged result."
  def cancel_task(server_name, task_id, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_cancel_task(server_name, task_id, opts) end,
        :value
      )

  @doc "Raising variant of `cancel_task/3`."
  def cancel_task!(server_name, task_id, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(cancel_task(server_name, task_id, opts))

  @doc "Runs `complete` and returns a tagged result."
  def complete(server_name, ref, argument, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_complete(server_name, ref, argument, opts) end,
        :value
      )

  @doc "Raising variant of `complete/4`."
  def complete!(server_name, ref, argument, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(complete(server_name, ref, argument, opts))

  @doc "Runs `component_manager` and returns a tagged result."
  def component_manager(server_name),
    do:
      FastestMCP.OperationResult.capture(fn -> execute_component_manager(server_name) end, :value)

  @doc "Raising variant of `component_manager/1`."
  def component_manager!(server_name),
    do: FastestMCP.OperationResult.unwrap!(component_manager(server_name))

  @doc "Runs `disable_components` and returns a tagged result."
  def disable_components(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_disable_components(server_name, opts) end,
        :value
      )

  @doc "Raising variant of `disable_components/2`."
  def disable_components!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(disable_components(server_name, opts))

  @doc "Runs `enable_components` and returns a tagged result."
  def enable_components(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_enable_components(server_name, opts) end,
        :value
      )

  @doc "Raising variant of `enable_components/2`."
  def enable_components!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(enable_components(server_name, opts))

  @doc "Runs `fetch_task` and returns a tagged result."
  def fetch_task(task),
    do: FastestMCP.OperationResult.capture(fn -> execute_fetch_task(task) end, :value)

  @doc "Raising variant of `fetch_task/1`."
  def fetch_task!(task), do: FastestMCP.OperationResult.unwrap!(fetch_task(task))

  @doc "Runs `fetch_task` and returns a tagged result."
  def fetch_task(server_name, task_id, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_fetch_task(server_name, task_id, opts) end,
        :value
      )

  @doc "Raising variant of `fetch_task/3`."
  def fetch_task!(server_name, task_id, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(fetch_task(server_name, task_id, opts))

  @doc "Runs `initialize` and returns a tagged result."
  def initialize(server_name, params \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_initialize(server_name, params, opts) end,
        :value
      )

  @doc "Raising variant of `initialize/3`."
  def initialize!(server_name, params \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(initialize(server_name, params, opts))

  @doc "Runs `list_prompts` and returns a tagged result."
  def list_prompts(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_list_prompts(server_name, opts) end,
        :value
      )

  @doc "Raising variant of `list_prompts/2`."
  def list_prompts!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_prompts(server_name, opts))

  @doc "Runs `list_resource_templates` and returns a tagged result."
  def list_resource_templates(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_list_resource_templates(server_name, opts) end,
        :value
      )

  @doc "Raising variant of `list_resource_templates/2`."
  def list_resource_templates!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_resource_templates(server_name, opts))

  @doc "Runs `list_resources` and returns a tagged result."
  def list_resources(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_list_resources(server_name, opts) end,
        :value
      )

  @doc "Raising variant of `list_resources/2`."
  def list_resources!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_resources(server_name, opts))

  @doc "Runs `list_tasks` and returns a tagged result."
  def list_tasks(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(fn -> execute_list_tasks(server_name, opts) end, :value)

  @doc "Raising variant of `list_tasks/2`."
  def list_tasks!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_tasks(server_name, opts))

  @doc "Runs `list_tools` and returns a tagged result."
  def list_tools(server_name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(fn -> execute_list_tools(server_name, opts) end, :value)

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(server_name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_tools(server_name, opts))

  @doc "Runs `notify_resource_updated` and returns a tagged result."
  def notify_resource_updated(server_name, uri),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_notify_resource_updated(server_name, uri) end,
        :command
      )

  @doc "Raising variant of `notify_resource_updated/2`."
  def notify_resource_updated!(server_name, uri),
    do: FastestMCP.OperationResult.unwrap!(notify_resource_updated(server_name, uri))

  @doc "Runs `ping` and returns a tagged result."
  def ping(server_name, params \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_ping(server_name, params, opts) end,
        :value
      )

  @doc "Raising variant of `ping/3`."
  def ping!(server_name, params \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(ping(server_name, params, opts))

  @doc "Runs `read_resource` and returns a tagged result."
  def read_resource(server_name, uri, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_read_resource(server_name, uri, opts) end,
        :value
      )

  @doc "Raising variant of `read_resource/3`."
  def read_resource!(server_name, uri, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(read_resource(server_name, uri, opts))

  @doc "Runs `render_prompt` and returns a tagged result."
  def render_prompt(server_name, name, arguments \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_render_prompt(server_name, name, arguments, opts) end,
        :value
      )

  @doc "Raising variant of `render_prompt/4`."
  def render_prompt!(server_name, name, arguments \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(render_prompt(server_name, name, arguments, opts))

  @doc "Runs `reset_component_visibility` and returns a tagged result."
  def reset_component_visibility(server_name),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_reset_component_visibility(server_name) end,
        :command
      )

  @doc "Raising variant of `reset_component_visibility/1`."
  def reset_component_visibility!(server_name),
    do: FastestMCP.OperationResult.unwrap!(reset_component_visibility(server_name))

  @doc "Runs `send_task_input` and returns a tagged result."
  def send_task_input(server_name, task_id, action, content \\ nil, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_send_task_input(server_name, task_id, action, content, opts) end,
        :value
      )

  @doc "Raising variant of `send_task_input/5`."
  def send_task_input!(server_name, task_id, action, content \\ nil, opts \\ []),
    do:
      FastestMCP.OperationResult.unwrap!(
        send_task_input(server_name, task_id, action, content, opts)
      )

  @doc "Runs `subscribe_task_notifications` and returns a tagged result."
  def subscribe_task_notifications(server_name, session_id, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_subscribe_task_notifications(server_name, session_id, opts) end,
        :value
      )

  @doc "Raising variant of `subscribe_task_notifications/3`."
  def subscribe_task_notifications!(server_name, session_id, opts \\ []),
    do:
      FastestMCP.OperationResult.unwrap!(
        subscribe_task_notifications(server_name, session_id, opts)
      )

  @doc "Runs `task_notification_subscriber_count` and returns a tagged result."
  def task_notification_subscriber_count(server_name),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_task_notification_subscriber_count(server_name) end,
        :value
      )

  @doc "Raising variant of `task_notification_subscriber_count/1`."
  def task_notification_subscriber_count!(server_name),
    do: FastestMCP.OperationResult.unwrap!(task_notification_subscriber_count(server_name))

  @doc "Runs `task_result` and returns a tagged result."
  def task_result(task),
    do: FastestMCP.OperationResult.capture(fn -> execute_task_result(task) end, :value)

  @doc "Raising variant of `task_result/1`."
  def task_result!(task), do: FastestMCP.OperationResult.unwrap!(task_result(task))

  @doc "Runs `task_result` and returns a tagged result."
  def task_result(server_name, task_id, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_task_result(server_name, task_id, opts) end,
        :value
      )

  @doc "Raising variant of `task_result/3`."
  def task_result!(server_name, task_id, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(task_result(server_name, task_id, opts))

  @doc "Runs `update_task` and returns a tagged result."
  def update_task(server_name, task_id, input_responses, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_update_task(server_name, task_id, input_responses, opts) end,
        :value
      )

  @doc "Raising variant of `update_task/4`."
  def update_task!(server_name, task_id, input_responses, opts \\ []),
    do:
      FastestMCP.OperationResult.unwrap!(update_task(server_name, task_id, input_responses, opts))
end
