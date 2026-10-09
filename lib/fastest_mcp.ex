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

  Operations on a running server return `{:ok, value}` (commands `:ok`) or
  `{:error, %FastestMCP.Error{}}`; each has a `!` variant that returns the value
  or raises the error.

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
  child = FastestMCP.streamable_http_child_spec("docs", port: 4100, allowed_hosts: :localhost)
  ```

  Prepare local tools for sampling:

  ```elixir
  tools = FastestMCP.prepare_sampling_tools("docs")
  ```

  Resolve tool-argument completion values:

  ```elixir
  FastestMCP.complete!(
    "docs",
    %{"type" => "ref/tool", "name" => "deploy"},
    %{"name" => "environment", "value" => "prev"}
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
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Pagination
  alias FastestMCP.Protocol
  alias FastestMCP.Provider
  alias FastestMCP.Providers.OpenAPI
  alias FastestMCP.Registry
  alias FastestMCP.Sampling
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TaskNotificationSubscriber
  alias FastestMCP.TaskOwner
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

  @doc "Builds a server definition; see `FastestMCP.Server.new/2` for the options."
  defdelegate server(name, opts \\ []), to: Server, as: :new
  @doc "Adds a tool; see `FastestMCP.Server.add_tool/4`."
  defdelegate add_tool(server, name, handler, opts \\ []), to: Server
  @doc "Adds a resource; see `FastestMCP.Server.add_resource/4`."
  defdelegate add_resource(server, uri, handler, opts \\ []), to: Server
  @doc "Adds a resource template; see `FastestMCP.Server.add_resource_template/4`."
  defdelegate add_resource_template(server, uri_template, handler, opts \\ []), to: Server
  @doc "Adds a prompt; see `FastestMCP.Server.add_prompt/4`."
  defdelegate add_prompt(server, name, handler, opts \\ []), to: Server
  @doc "Adds an HTTP route; see `FastestMCP.Server.add_http_route/4`."
  defdelegate add_http_route(server, method, path, handler), to: Server
  @doc "Registers a dependency resolver; see `FastestMCP.Server.add_dependency/3`."
  defdelegate add_dependency(server, name, resolver), to: Server
  @doc "Appends middleware; see `FastestMCP.Server.add_middleware/2`."
  defdelegate add_middleware(server, middleware), to: Server
  @doc "Enables bounded model-visible tool search on the server."
  defdelegate enable_tool_search(server, opts \\ []), to: Server
  @doc "Adds a component transform; see `FastestMCP.Server.add_transform/2`."
  defdelegate add_transform(server, transform), to: Server
  @doc "Adds a component provider; see `FastestMCP.Provider`."
  defdelegate add_provider(server, provider), to: Server
  @doc "Adds an executable root extension, overriding provider bundles with the same identifier."
  defdelegate add_extension(server, extension), to: Server
  @doc "Exposes another server's components; see `FastestMCP.Server.mount/3`."
  defdelegate mount(server, mounted_server, opts \\ []), to: Server
  @doc "Adds a transform to a provider wrapper."
  defdelegate add_provider_transform(provider, transform), to: Provider, as: :add_transform

  @doc """
  Builds a server definition whose tools are the operations of a decoded
  OpenAPI document.

  Options: `:name` (default: the document's `info.title`), `:base_url`
  (default: its first server URL), `:timeout_ms` per request (default 5,000),
  `:schema_options`, and `:requester`, a `fn method, url, opts -> {:ok,
  status, headers, body} | {:error, reason} end` that replaces the HTTP client
  (for example in tests).
  """
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

  @doc "Sets the authenticator; see `FastestMCP.Server.add_auth/3`."
  def add_auth(%Server{} = server, provider_or_auth, opts \\ []) do
    Server.add_auth(server, provider_or_auth, opts)
  end

  @doc "Adds a lifespan; see `FastestMCP.Lifespan`."
  def add_lifespan(%Server{} = server, lifespan) do
    Server.add_lifespan(server, lifespan)
  end

  @doc "Adds a lifespan from `enter` and `exit` functions; see `FastestMCP.Lifespan.new/2`."
  def add_lifespan(%Server{} = server, enter, exit) do
    Server.add_lifespan(server, enter, exit)
  end

  @doc """
  Starts the runtime of a `%FastestMCP.Server{}` or a `FastestMCP.ServerModule`
  module under the library's supervisor.

  For a server, `opts` are runtime options, among them `:max_sessions`
  (default 10,000), `:session_idle_ttl` (default 15 minutes),
  `:max_concurrent_calls`, `:max_background_tasks`, `:strict_request_ids`,
  and the `:session_state_store` and `:task_backend` backends; unknown options
  raise `ArgumentError`. For a server module, `opts` override its
  configuration.
  """
  def start_server(server_or_module, opts \\ [])

  def start_server(%Server{} = server, opts) do
    ServerRuntime.start(server, opts)
  end

  def start_server(module, opts) when is_atom(module) and is_list(opts) do
    if FastestMCP.ServerModule.server_module?(module) do
      FastestMCP.ServerSupervisor
      |> DynamicSupervisor.start_child(module.child_spec(opts))
      |> FastestMCP.ServerSupervisor.unwrap_start_error()
    else
      raise ArgumentError,
            "#{inspect(module)} is not a FastestMCP server module. Use `use FastestMCP.ServerModule` and implement server/1."
    end
  end

  @doc "Starts a server runtime, raising on failure."
  def start_server!(server_or_module, opts \\ []),
    do: Error.unwrap!(start_server(server_or_module, opts))

  @doc "Stops a running server runtime."
  defdelegate stop_server(server_name), to: ServerRuntime, as: :stop

  @doc "Stops a running server runtime, raising on failure."
  def stop_server!(server_name), do: Error.unwrap!(stop_server(server_name))

  @doc """
  Completes a URL elicitation for the user it was issued to, identified by
  `:principal` (with `:auth`) or `:auth_result`. Returns `{:ok, elicitation}`
  or `{:error, reason}` with reason `:forbidden`, `:expired`,
  `:already_completed`, or `:not_found`.
  """
  def complete_elicitation(server_name, elicitation_id, opts)
      when is_binary(elicitation_id) and is_list(opts) do
    with {:ok, fingerprint} <- completion_identity_fingerprint(opts),
         {:ok, session_id, _session_pid} <-
           Registry.lookup_url_elicitation(server_name, elicitation_id) do
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

        {:error, reason} when reason in [:declined, :not_found] ->
          {:error, :not_found}

        {:error, _reason} ->
          {:error, :forbidden}
      end
    end
  end

  @doc "Completes a URL elicitation, raising on failure."
  def complete_elicitation!(server_name, elicitation_id, opts),
    do: Error.unwrap!(complete_elicitation(server_name, elicitation_id, opts))

  @doc """
  Returns the plug `{FastestMCP.Transport.HTTPApp, opts}` serving the MCP
  endpoint of the running server `server_name`; `opts` are the
  `FastestMCP.Transport.HTTPApp` options, such as `:allowed_hosts`, validated
  here. Give it to Bandit as `plug:`, or run it with `Plug.run/2`:

      {Bandit, plug: FastestMCP.http_app(MyApp.MCPServer, allowed_hosts: :localhost)}
  """
  def http_app(server_name, opts \\ []),
    do: {HTTPApp, HTTPApp.init(Keyword.put(opts, :server_name, server_name))}

  @doc "Returns a Bandit child spec serving the server over Streamable HTTP; see `FastestMCP.Transport.StreamableHTTP`."
  def streamable_http_child_spec(server_name, opts \\ []) do
    StreamableHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Returns a Bandit child spec serving its protected resource metadata; see `FastestMCP.Transport.WellKnownHTTP`."
  def well_known_http_child_spec(server_name, opts \\ []) do
    WellKnownHTTP.child_spec(Keyword.put(opts, :server_name, server_name))
  end

  @doc "Handles one stdio message; see `FastestMCP.Transport.Stdio.dispatch/3`."
  def stdio_dispatch(server_name, request, opts \\ []) do
    Stdio.dispatch(server_name, request, opts)
  end

  @doc "Runs the MCP initialize handshake."
  defdelegate initialize(server_name, params \\ %{}, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `initialize/3`."
  def initialize!(server_name, params \\ %{}, opts \\ []),
    do: Error.unwrap!(initialize(server_name, params, opts))

  @doc "Runs a ping request."
  defdelegate ping(server_name, params \\ %{}, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `ping/3`."
  def ping!(server_name, params \\ %{}, opts \\ []),
    do: Error.unwrap!(ping(server_name, params, opts))

  @doc "Lists visible tools."
  defdelegate list_tools(server_name, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(server_name, opts \\ []), do: Error.unwrap!(list_tools(server_name, opts))

  @doc "Lists visible resources."
  defdelegate list_resources(server_name, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `list_resources/2`."
  def list_resources!(server_name, opts \\ []),
    do: Error.unwrap!(list_resources(server_name, opts))

  @doc "Lists visible resource templates."
  defdelegate list_resource_templates(server_name, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `list_resource_templates/2`."
  def list_resource_templates!(server_name, opts \\ []),
    do: Error.unwrap!(list_resource_templates(server_name, opts))

  @doc "Lists visible prompts."
  defdelegate list_prompts(server_name, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `list_prompts/2`."
  def list_prompts!(server_name, opts \\ []), do: Error.unwrap!(list_prompts(server_name, opts))

  @doc "Calls a tool with the given arguments."
  defdelegate call_tool(server_name, name, arguments \\ %{}, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(server_name, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(call_tool(server_name, name, arguments, opts))

  @doc "Reads a resource by URI."
  defdelegate read_resource(server_name, uri, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `read_resource/3`."
  def read_resource!(server_name, uri, opts \\ []),
    do: Error.unwrap!(read_resource(server_name, uri, opts))

  @doc "Renders a prompt with the given arguments."
  defdelegate render_prompt(server_name, name, arguments \\ %{}, opts \\ []),
    to: OperationPipeline

  @doc "Raising variant of `render_prompt/4`."
  def render_prompt!(server_name, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(render_prompt(server_name, name, arguments, opts))

  @doc "Resolves completion values for a prompt argument or resource-template parameter."
  defdelegate complete(server_name, ref, argument, opts \\ []), to: OperationPipeline

  @doc "Raising variant of `complete/4`."
  def complete!(server_name, ref, argument, opts \\ []),
    do: Error.unwrap!(complete(server_name, ref, argument, opts))

  @doc "Returns the live component manager of a running server."
  def component_manager(server_name),
    do: with_runtime(server_name, &{:ok, &1.component_manager})

  @doc "Raising variant of `component_manager/1`."
  def component_manager!(server_name), do: Error.unwrap!(component_manager(server_name))

  @doc "Enables matching components for every session of a running server."
  defdelegate enable_components(server_name, opts \\ []), to: ComponentVisibility, as: :enable

  @doc "Raising variant of `enable_components/2`."
  def enable_components!(server_name, opts \\ []),
    do: Error.unwrap!(enable_components(server_name, opts))

  @doc "Disables matching components for every session of a running server."
  defdelegate disable_components(server_name, opts \\ []), to: ComponentVisibility, as: :disable

  @doc "Raising variant of `disable_components/2`."
  def disable_components!(server_name, opts \\ []),
    do: Error.unwrap!(disable_components(server_name, opts))

  @doc "Removes every server-wide visibility rule."
  defdelegate reset_component_visibility(server_name), to: ComponentVisibility, as: :reset

  @doc "Raising variant of `reset_component_visibility/1`."
  def reset_component_visibility!(server_name),
    do: Error.unwrap!(reset_component_visibility(server_name))

  @doc "Notifies subscribed sessions that one concrete resource URI changed."
  def notify_resource_updated(server_name, uri) do
    with_runtime(server_name, fn runtime ->
      EventBus.emit(
        runtime.event_bus,
        server_name,
        [:resources, :updated],
        %{count: 1},
        %{uri: to_string(uri)}
      )
    end)
  end

  @doc "Raising variant of `notify_resource_updated/2`."
  def notify_resource_updated!(server_name, uri),
    do: Error.unwrap!(notify_resource_updated(server_name, uri))

  @doc "Starts a task-notification subscriber for one session."
  def subscribe_task_notifications(server_name, session_id, opts \\ []) do
    with_runtime(server_name, fn runtime ->
      opts =
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

      case DynamicSupervisor.start_child(
             runtime.notification_supervisor,
             {TaskNotificationSubscriber, opts}
           ) do
        {:error, reason} -> {:error, Error.internal("operation failed", %{reason: reason})}
        started -> started
      end
    end)
  end

  @doc "Raising variant of `subscribe_task_notifications/3`."
  def subscribe_task_notifications!(server_name, session_id, opts \\ []),
    do: Error.unwrap!(subscribe_task_notifications(server_name, session_id, opts))

  @doc "Returns the number of task-notification subscribers."
  def task_notification_subscriber_count(server_name) do
    with_runtime(server_name, fn runtime ->
      {:ok,
       runtime.notification_supervisor
       |> DynamicSupervisor.which_children()
       |> Enum.count(&match?({_id, _pid, _type, [TaskNotificationSubscriber]}, &1))}
    end)
  end

  @doc "Raising variant of `task_notification_subscriber_count/1`."
  def task_notification_subscriber_count!(server_name),
    do: Error.unwrap!(task_notification_subscriber_count(server_name))

  @doc "Fetches the current state of a background task."
  def fetch_task(%BackgroundTask{} = task),
    do: fetch_task(task.server_name, task.task_id, handle_access_opts(task))

  @doc "Fetches the current state of the background task `task_id`."
  def fetch_task(server_name, task_id, opts \\ []) do
    task_call(server_name, task_id, opts, :fetch, &BackgroundTaskStore.fetch(&1, task_id, &2))
  end

  @doc "Raising variant of `fetch_task/1`."
  def fetch_task!(task), do: Error.unwrap!(fetch_task(task))

  @doc "Raising variant of `fetch_task/3`."
  def fetch_task!(server_name, task_id, opts \\ []),
    do: Error.unwrap!(fetch_task(server_name, task_id, opts))

  @doc "Waits up to `timeout` for a background task to finish."
  def await_task(%BackgroundTask{} = task, timeout \\ 5_000),
    do: await_task(task.server_name, task.task_id, timeout, handle_access_opts(task))

  @doc "Waits up to `timeout` for the background task `task_id` to finish."
  def await_task(server_name, task_id, timeout, opts \\ []) do
    task_call(server_name, task_id, opts, :await, fn store, opts ->
      BackgroundTaskStore.await(store, task_id, timeout, opts)
    end)
  end

  @doc "Raising variant of `await_task/2`."
  def await_task!(task, timeout \\ 5_000), do: Error.unwrap!(await_task(task, timeout))

  @doc "Raising variant of `await_task/4`."
  def await_task!(server_name, task_id, timeout, opts \\ []),
    do: Error.unwrap!(await_task(server_name, task_id, timeout, opts))

  @doc "Returns the final result of a background task, waiting for it to finish."
  def task_result(%BackgroundTask{} = task),
    do: task_result(task.server_name, task.task_id, handle_access_opts(task))

  @doc "Returns the final result of the background task `task_id`, waiting for it to finish."
  def task_result(server_name, task_id, opts \\ []) do
    task_call(server_name, task_id, opts, :result, fn store, opts ->
      BackgroundTaskStore.await(store, task_id, Keyword.get(opts, :timeout, 60_000), opts)
    end)
  end

  @doc "Raising variant of `task_result/1`."
  def task_result!(task), do: Error.unwrap!(task_result(task))

  @doc "Raising variant of `task_result/3`."
  def task_result!(server_name, task_id, opts \\ []),
    do: Error.unwrap!(task_result(server_name, task_id, opts))

  @doc """
  Lists the background tasks visible to the caller, newest first.

  With `:page_size`, returns one page; pass its `:next_cursor` as `:cursor` for
  the next.
  """
  def list_tasks(server_name, opts \\ []) do
    with {:ok, tasks} <- task_call(server_name, nil, opts, :list, &BackgroundTaskStore.list/2),
         {:ok, page} <- Pagination.maybe_paginate(tasks, opts) do
      case page do
        %{items: tasks, next_cursor: cursor} -> {:ok, %{tasks: tasks, next_cursor: cursor}}
        tasks -> {:ok, %{tasks: tasks, next_cursor: nil}}
      end
    end
  end

  @doc "Raising variant of `list_tasks/2`."
  def list_tasks!(server_name, opts \\ []), do: Error.unwrap!(list_tasks(server_name, opts))

  @doc "Cancels a background task."
  def cancel_task(%BackgroundTask{} = task),
    do: cancel_task(task.server_name, task.task_id, handle_access_opts(task))

  @doc "Cancels the background task `task_id`."
  def cancel_task(server_name, task_id, opts \\ []) do
    task_call(server_name, task_id, opts, :cancel, &BackgroundTaskStore.cancel(&1, task_id, &2))
  end

  @doc "Raising variant of `cancel_task/1`."
  def cancel_task!(task), do: Error.unwrap!(cancel_task(task))

  @doc "Raising variant of `cancel_task/3`."
  def cancel_task!(server_name, task_id, opts \\ []),
    do: Error.unwrap!(cancel_task(server_name, task_id, opts))

  @doc "Answers input requests outstanding for a background task."
  def update_task(server_name, task_id, input_responses, opts \\ []) do
    task_call(server_name, task_id, opts, :update, fn store, opts ->
      BackgroundTaskStore.update(store, task_id, input_responses, opts)
    end)
  end

  @doc "Raising variant of `update_task/4`."
  def update_task!(server_name, task_id, input_responses, opts \\ []),
    do: Error.unwrap!(update_task(server_name, task_id, input_responses, opts))

  @doc "Sends interactive input back to a background task that is waiting for it."
  def send_task_input(server_name, task_id, action, content \\ nil, opts \\ []) do
    task_call(server_name, task_id, opts, :send_input, fn store, opts ->
      BackgroundTaskStore.send_input(store, task_id, action, content, opts)
    end)
  end

  @doc "Raising variant of `send_task_input/5`."
  def send_task_input!(server_name, task_id, action, content \\ nil, opts \\ []),
    do: Error.unwrap!(send_task_input(server_name, task_id, action, content, opts))

  # Runs `fun` with the runtime of a running server; process exits, such as a
  # runtime stopping mid-call, become errors.
  defp with_runtime(server_name, fun) do
    with {:ok, runtime} <- ServerRuntime.fetch_running(server_name), do: fun.(runtime)
  catch
    :exit, reason -> {:error, Error.from_exit(reason)}
  end

  defp task_call(server_name, task_id, opts, operation, fun) do
    opts = task_access_opts(server_name, opts)

    with_runtime(server_name, fn runtime ->
      case fun.(runtime.task_store, opts) do
        {:error, :not_found} when not is_nil(task_id) ->
          {:error, Error.invalid_task_id(task_id)}

        {:error, reason} when not is_exception(reason) ->
          {:error,
           Error.internal("background task storage #{operation} failed", %{
             reason: inspect(reason)
           })}

        result ->
          result
      end
    end)
  end

  defp task_access_opts(server_name, opts) do
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

    Keyword.put_new(opts, :owner_fingerprint, owner_fingerprint)
  end

  defp handle_access_opts(%BackgroundTask{owner_fingerprint: owner_fingerprint})
       when is_binary(owner_fingerprint) and owner_fingerprint != "",
       do: [owner_fingerprint: owner_fingerprint]

  defp handle_access_opts(%BackgroundTask{}), do: []

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
end
