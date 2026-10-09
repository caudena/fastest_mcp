defmodule FastestMCP.Client.Connection do
  @moduledoc false
  # The connected client's process: a GenServer shell over cores that each
  # own one sub-struct of `FastestMCP.Client.Connection.State`.
  use GenServer

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client
  alias FastestMCP.Client.Config
  alias FastestMCP.Client.Connection.CallbackTasks
  alias FastestMCP.Client.Connection.Catalog
  alias FastestMCP.Client.Connection.Dispatcher
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Notifications
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.Outbound.Request
  alias FastestMCP.Client.Connection.Recovery
  alias FastestMCP.Client.Connection.SessionStream
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.Connection.Stdio
  alias FastestMCP.Client.Connection.TaskRegistry
  alias FastestMCP.Client.HTTP
  alias FastestMCP.Client.Info
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.Options
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.RemoteTasks
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Client.Transport, as: ClientTransport
  alias FastestMCP.Client.TransportSnapshot
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Util

  def start_link(opts) do
    {target, opts} = pop_target!(opts)
    start(Options.validate!(target, Keyword.delete(opts, :id)))
  end

  def child_spec(opts) do
    {target, client_opts} = pop_target!(opts)
    {child, client_opts} = Keyword.split(client_opts, [:id, :restart])
    config = Options.validate!(target, client_opts)
    restart = Keyword.get(child, :restart, :permanent)

    unless restart in [:permanent, :transient, :temporary] do
      raise ArgumentError,
            "client child restart must be :permanent, :transient, or :temporary, got: #{inspect(restart)}"
    end

    %{
      id: Keyword.get(child, :id, config.name || Client),
      start: {Client, :start_link, [Keyword.drop(opts, [:id, :restart])]},
      restart: restart,
      shutdown: 20000,
      type: :worker
    }
  end

  defp pop_target!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "client options must be a keyword list")

    case Keyword.pop(opts, :target) do
      {nil, _opts} -> raise ArgumentError, "client start options require a :target"
      target_and_opts -> target_and_opts
    end
  end

  def connect(target, opts) do
    with {:ok, pid} <- start(Options.validate!(target, opts)), do: {:ok, %Client{pid: pid}}
  end

  defp start(%Config{} = config) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, config, name: config.name) do
      case if(config.auto_initialize, do: negotiate(%Client{pid: pid}, config), else: :ok) do
        :ok ->
          {:ok, pid}

        {:error, error} ->
          stop_failed_client(pid)
          {:error, error}
      end
    end
  end

  defp stop_failed_client(pid) do
    Process.unlink(pid)
    Util.stop_process(pid, :shutdown)
  end

  # Succeeds only once the transport proves its resources are released.
  def disconnect(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %Client{pid: pid}} -> GenServer.call(pid, :disconnect, 5000)
      :error -> :ok
    end
  catch
    # Idempotent: a client that already stopped, or stops while we ask
    # (for example because its owner exited), has run its cleanup.
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:noproc, :normal, :shutdown] or
           (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
      :ok

    :exit, reason ->
      {:error, exit_error(reason)}
  end

  def connected?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %Client{pid: pid}} -> Process.alive?(pid)
      :error -> false
    end
  end

  def ready?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, client} -> call(client, :ready?) == true
      :error -> false
    end
  end

  def await_ready(client_ref, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    named? = not match?(%Client{}, client_ref) and not is_pid(client_ref)
    await_ready_until(client_ref, Deadline.new(timeout), named?)
  end

  def await_ready(_client_ref, timeout) do
    raise ArgumentError,
          "ready timeout must be :infinity or a non-negative integer, got: #{inspect(timeout)}"
  end

  # The connection answers when it becomes ready, fails, or the deadline
  # passes. A named reference follows a supervisor's replacement process
  # until the deadline; the name may be unregistered for a moment meanwhile.
  defp await_ready_until(client_ref, deadline, named?) do
    remaining = Deadline.remaining(deadline)

    reply =
      try do
        with {:ok, %Client{pid: pid}} <- resolve_client(client_ref),
             do: GenServer.call(pid, {:await_ready, remaining}, call_timeout(remaining))
      catch
        :exit, {:timeout, _call} -> {:error, readiness_timeout_error(deadline)}
        :exit, _reason -> :error
      end

    case reply do
      :error when named? and remaining != 0 ->
        Process.sleep(min(remaining, 10))
        await_ready_until(client_ref, deadline, named?)

      :error when named? ->
        {:error, readiness_timeout_error(deadline)}

      :error ->
        {:error, client_not_running_error()}

      reply ->
        reply
    end
  end

  defp readiness_timeout_error(:infinity),
    do: %Error{code: :timeout, message: "MCP client did not become ready"}

  defp readiness_timeout_error(_deadline),
    do: %Error{code: :timeout, message: "MCP client did not become ready before the deadline"}

  defp client_not_running_error,
    do: %Error{code: :internal_error, message: "MCP client is not running"}

  def info(client_ref), do: call_ref(client_ref, :info)

  def set_handler(client_ref, key, handler) do
    Options.handler!(key, handler)
    call_ref(client_ref, {:set_handler, key, handler})
  end

  # Replaces every credential of the connection.
  def set_auth(client_ref, opts),
    do: call_ref(client_ref, {:set_auth, Options.auth_input!(opts)})

  def set_roots(client_ref, roots) when is_list(roots),
    do: call_ref(client_ref, {:set_roots, roots})

  def open_session_stream(client_ref), do: call_ref(client_ref, :open_session_stream)
  def close_session_stream(client_ref), do: call_ref(client_ref, :close_session_stream)

  defp call_ref(client_ref, request),
    do: with({:ok, client} <- pin(client_ref), do: call(client, request))

  # Pins a client reference to its current process for one operation.
  def pin(client_ref) do
    case resolve_client(client_ref) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, client_not_running_error()}
    end
  end

  # The way callers reach a pinned connection: an exit becomes an error.
  def call(%Client{pid: pid}, request, timeout \\ 5_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, reason -> {:error, exit_error(reason)}
  end

  def exit_error(reason), do: Error.from_exit(reason)

  def call_timeout(:infinity), do: :infinity
  def call_timeout(timeout_ms), do: timeout_ms + 1000

  defp resolve_client(%Client{pid: pid} = client) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, client}, else: :error
  end

  defp resolve_client(client_ref) do
    case GenServer.whereis(client_ref) do
      pid when is_pid(pid) -> {:ok, %Client{pid: pid}}
      nil -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp negotiate(client, config) do
    with {:ok, version} <- negotiate_version(client, config) do
      if config.session_stream and is_legacy(version),
        do: call(client, :open_session_stream),
        else: :ok
    end
  end

  # :auto falls back to initialize only on credible legacy evidence.
  defp negotiate_version(client, %Config{} = config) do
    opts = [timeout_ms: config.init_timeout_ms]

    case config.protocol_version do
      legacy() ->
        initialize(client, opts)

      modern() ->
        discover(client, opts)

      :auto ->
        with {:error, error} <- discover(client, opts) do
          if legacy_fallback_evidence?(error, config.transport.type),
            do: initialize(client, opts),
            else: {:error, error}
        end
    end
  end

  defp initialize(client, opts) do
    with {:ok, _result} <- FastestMCP.Client.Requests.initialize(client, %{}, opts),
         do: {:ok, legacy()}
  end

  defp discover(client, opts) do
    with {:ok, _result} <- FastestMCP.Client.Requests.discover(client, opts), do: {:ok, modern()}
  end

  defp legacy_fallback_evidence?(%ProtocolError{method: "server/discover"}, :stdio), do: true
  defp legacy_fallback_evidence?(%ProtocolError{}, :streamable_http), do: false

  defp legacy_fallback_evidence?(%Error{} = error, :stdio),
    do: not recognized_modern_discovery_error?(error)

  defp legacy_fallback_evidence?(%Error{} = error, :streamable_http) do
    details = if is_map(error.details), do: error.details, else: %{}
    status = Map.get(details, :status)
    jsonrpc_code = Map.get(details, :jsonrpc_code)

    not recognized_modern_discovery_error?(error) and
      (jsonrpc_code == -32601 or
         (status == 400 and (is_nil(jsonrpc_code) or is_integer(jsonrpc_code))) or
         (status in [404, 405] and is_nil(jsonrpc_code)))
  end

  defp legacy_fallback_evidence?(_error, _transport), do: false

  defp recognized_modern_discovery_error?(%Error{code: code, details: details}) do
    jsonrpc_code = if is_map(details), do: Map.get(details, :jsonrpc_code)

    code in [:header_mismatch, :missing_required_client_capability, :unsupported_protocol_version] or
      jsonrpc_code in [-32020, -32021, -32022]
  end

  ## Process

  @impl true
  def init(%Config{} = config) do
    state = State.new(config)

    # Returning {:error, reason} (not {:stop, reason}) keeps a linked caller
    # alive; the worker supervisor follows this process out on its own.
    with {:ok, worker_supervisor} <- Task.Supervisor.start_link(),
         {:ok, state} <- start_oauth(%{state | worker_supervisor: worker_supervisor}) do
      Process.flag(:trap_exit, true)
      state |> start_dispatcher() |> open_client_transport()
    end
  end

  defp start_dispatcher(state) do
    dispatcher = Dispatcher.start(state.worker_supervisor)
    {_ref, state} = State.monitor(state, dispatcher, :dispatcher)
    %{state | dispatcher: dispatcher}
  end

  defp start_oauth(%State{config: %Config{oauth: nil}} = state), do: {:ok, state}

  # `Client.Options` validated the OAuth options into an `%OAuth.Config{}`.
  defp start_oauth(%State{config: config} = state) do
    case GenServer.start_link(OAuth, %{config.oauth | credential_listener: self()}) do
      {:ok, pid} ->
        oauth = %{
          pid: pid,
          resource: state.transport.base_url,
          max_auth_attempts: config.max_auth_attempts
        }

        {:ok, %{state | oauth: oauth}}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "failed to start OAuth client",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp stop_oauth(%{oauth: %{pid: pid}}) when is_pid(pid), do: Util.stop_process(pid)

  defp stop_oauth(_state), do: :ok

  defp open_client_transport(state) do
    case ClientTransport.open(state.transport, self(), auth_input: state.config.auth_input) do
      {:ok, transport} ->
        {:ok, %{state | transport: transport}}

      {:error, reason} ->
        stop_oauth(state)

        {:error,
         case reason do
           %Error{} = error ->
             error

           reason ->
             %Error{
               code: :internal_error,
               message: "failed to open client transport",
               details: %{transport: state.transport.type, reason: inspect(reason)}
             }
         end}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = SessionStream.stop(state, nil)

    Enum.each(Map.values(state.outbound.requests), fn request ->
      Outbound.notify_cancelled(state, request, "client disconnected")
      {request, _state} = Outbound.take(state, request.ref)
      Outbound.finish_trace(request, {:error, client_not_running_error()})
    end)

    if is_pid(state.worker_supervisor) and Process.alive?(state.worker_supervisor) do
      Supervisor.stop(state.worker_supervisor, :normal)
    end

    # The session DELETE builds its headers through OAuth, so it must run
    # before the OAuth process stops.
    HTTP.terminate_session(TransportSnapshot.new(state, true))
    stop_oauth(state)
    ClientTransport.close(state.transport)
    :ok
  end

  ## Calls

  @impl true
  def handle_call(:info, _from, %{lifecycle: lifecycle} = state) do
    info = %Info{
      session_id: lifecycle.session_id,
      protocol_version: lifecycle.protocol_version,
      capabilities: Lifecycle.server_capabilities(lifecycle),
      initialize_result: if(lifecycle.phase == :initialized, do: lifecycle.initialize_result),
      discovery_result: lifecycle.discovery_result,
      session_stream_open?: SessionStream.started?(state)
    }

    {:reply, {:ok, info}, state}
  end

  # A transport that cannot prove its resources released keeps the client.
  def handle_call(:disconnect, _from, state) do
    case retire_transport(state) do
      {:ok, state} ->
        {:stop, :normal, :ok, state}

      {:error, reason, state} ->
        message = "client transport did not release its resources"
        error = Error.internal(message, %{reason: reason})
        {:reply, {:error, error}, put_in(state.lifecycle.disconnecting?, true)}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, Lifecycle.snapshot(state)}, state}
  def handle_call(:ready?, _from, state), do: {:reply, Lifecycle.ready?(state), state}

  def handle_call({:await_ready, timeout}, from, state) do
    cond do
      Lifecycle.ready?(state) ->
        {:reply, :ok, state}

      state.lifecycle.phase == :failed ->
        {:reply, {:error, Lifecycle.readiness_error(state.lifecycle)}, state}

      true ->
        {:noreply, Lifecycle.add_waiter(state, from, timeout)}
    end
  end

  def handle_call(:begin_initialize, {owner, _tag}, state) do
    case Lifecycle.begin_initialize(state.lifecycle, state.config.protocol_version) do
      {:ok, lifecycle} -> {:reply, :ok, negotiating(%{state | lifecycle: lifecycle}, owner)}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:begin_discover, {owner, _tag}, state) do
    case Lifecycle.begin_discover(state.lifecycle, state.config.protocol_version) do
      {:ok, token, lifecycle} ->
        {:reply, {:ok, token}, negotiating(%{state | lifecycle: lifecycle}, owner)}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:finish_initialize, _from, state),
    do: negotiated(state, Lifecycle.finish_initialize(state.lifecycle))

  def handle_call({:finish_discover, token, result}, _from, state),
    do: negotiated(state, Lifecycle.finish_discover(state.lifecycle, token, result))

  def handle_call(:fail_initialize, _from, state), do: {:reply, :ok, failed_initialize(state)}

  def handle_call({:fail_discover, token}, _from, state),
    do: {:reply, :ok, failed_discover(state, token)}

  # Advertised callback capabilities are fixed once initialized.
  def handle_call({:set_handler, key, handler}, _from, %{config: config} = state) do
    if is_nil(state.lifecycle.initialize_result) or
         key not in [:sampling_handler, :elicitation_handler, :url_elicitation_handler] or
         is_nil(Map.fetch!(config, key)) == is_nil(handler) do
      {:reply, :ok, %{state | config: Map.put(config, key, handler)}}
    else
      {:reply,
       {:error,
        %Error{
          code: :bad_request,
          message: "callback capabilities cannot change after initialization",
          details: %{handler: key}
        }}, state}
    end
  end

  def handle_call({:set_roots, roots}, _from, state) do
    with true <- is_list(state.config.roots),
         {:ok, normalized} <- Options.roots(roots) do
      if normalized == state.config.roots do
        {:reply, :ok, state}
      else
        next = put_in(state.config.roots, normalized) |> Catalog.invalidate(:roots_changed)

        result =
          if state.lifecycle.initialize_result,
            do: own_notify(next, "notifications/roots/list_changed", %{}, []),
            else: :ok

        case result do
          :ok -> {:reply, :ok, next}
          {:error, %Error{} = error} -> {:reply, {:error, error}, state}
        end
      end
    else
      false ->
        {:reply,
         {:error,
          %Error{
            code: :bad_request,
            message: "roots support must be configured before initialization"
          }}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:callback_cancelled?, request_id, task_id}, _from, state),
    do: {:reply, CallbackTasks.cancelled?(state.callbacks, request_id, task_id), state}

  def handle_call({:report_callback_progress, context, progress, opts}, _from, state) do
    case CallbackTasks.progress(state, context, progress, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:set_auth, auth_input}, _from, state),
    do: {:reply, :ok, rotate_auth(put_in(state.config.auth_input, auth_input))}

  # Session-bound calls wait for session recovery and replay through
  # handle_call/3 once it finishes.
  def handle_call(request, from, %{lifecycle: %{phase: :recovering}} = state)
      when is_tuple(request) and elem(request, 0) in [:notification, :request, :request_async],
      do: Recovery.enqueue(state, from, request)

  def handle_call({:notification, method, params, opts}, {owner, _tag}, state) do
    with :ok <- Outbound.check_budget(owner, opts[:deadline]),
         :ok <- Lifecycle.check_notification(state.lifecycle, method) do
      {:reply, own_notify(state, method, params, opts), state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # A tracked task's status is recorded before its kind and target.
  def handle_call({:track_task, task_id, status, kind, target, output_validator}, _from, state) do
    state = if status, do: Notifications.task_status(state, task_id, status), else: state
    tasks = TaskRegistry.register(state.tasks, task_id, kind, target, output_validator)
    task = %RemoteTask{client: %Client{pid: self()}, task_id: task_id, kind: kind, target: target}
    {:reply, {:ok, task}, SessionStream.ensure_for_tasks(%{state | tasks: tasks})}
  end

  def handle_call({:task, task_id}, _from, state) do
    info =
      state.tasks
      |> TaskRegistry.fetch(task_id)
      |> Map.take([:status, :result, :origin_method, :output_validator])
      |> Map.put(:protocol_version, state.lifecycle.protocol_version)

    {:reply, {:ok, info}, state}
  end

  def handle_call({:cache_task_statuses, statuses}, _from, state) do
    state =
      Enum.reduce(statuses, state, fn {task_id, status}, state ->
        Notifications.task_status(state, task_id, status)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:cache_task_result, task_id, result}, _from, state),
    do: {:reply, :ok, update_in(state.tasks, &TaskRegistry.put_result(&1, task_id, result))}

  def handle_call({:register_task_callback, task_id, callback}, _from, state) do
    ref = make_ref()
    {:reply, :ok, update_in(state.tasks, &TaskRegistry.add_callback(&1, task_id, ref, callback))}
  end

  def handle_call({:wait_task_notification, task_id, targets, timeout_ms}, from, state) do
    state = SessionStream.ensure_for_tasks(state)
    status = TaskRegistry.fetch(state.tasks, task_id).status

    if TaskRegistry.matches?(status, targets) do
      {:reply, {:ok, status}, state}
    else
      ref = make_ref()
      timer = Process.send_after(self(), {:task_wait_timeout, task_id, ref}, timeout_ms)
      waiter = %{from: from, target_statuses: targets, timer: timer}
      {:noreply, update_in(state.tasks, &TaskRegistry.add_waiter(&1, task_id, ref, waiter))}
    end
  end

  def handle_call(:catalog_revision, _from, %{catalog: catalog} = state) do
    {:reply,
     {:ok,
      %{
        generation: catalog.tools.generation,
        fresh?: catalog.ready? and ToolCatalog.fresh?(catalog.tools),
        ready?: Lifecycle.ready?(state)
      }}, state}
  end

  # A caller with its own credentials loads a private catalog.
  def handle_call({:tool_catalog, :private, _select}, _from, state),
    do: {:reply, Catalog.load_reply(state), state}

  def handle_call({:tool_catalog, mode, select}, from, state) do
    state =
      if mode in [:refresh, :bypass] and is_nil(state.catalog.load),
        do: Catalog.invalidate(state, :explicit_refresh),
        else: state

    Catalog.ensure(state, from, select)
  end

  def handle_call({:install_tool_catalog, generation, result, select}, from, state) do
    {reply, state} = Catalog.install(state, from, generation, result, select)
    {:reply, reply, state}
  end

  def handle_call(:open_session_stream, from, state), do: SessionStream.open(state, from)

  def handle_call(:close_session_stream, _from, state),
    do: {:reply, :ok, SessionStream.close(state)}

  def handle_call({:session_stream, ref, {:recover, stale_session_id, _error}}, from, state) do
    if match?(%{ref: ^ref}, state.session_stream) and
         state.lifecycle.session_id == stale_session_id do
      {:noreply, Recovery.begin(state, {:stream, from})}
    else
      {:reply,
       {:error, %Error{code: :bad_request, message: "session stream recovery was superseded"}},
       state}
    end
  end

  def handle_call({:request, %Spec{} = spec}, from, state) do
    case Outbound.start(state, spec, {:sync, from}) do
      {:ok, _request, state} -> {:noreply, state}
      {:cached, result, state} -> {:reply, {:ok, result}, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request_async, %Spec{} = spec, owner}, _from, state) do
    case Outbound.start(state, spec, {:async, owner}) do
      {:ok, request, state} ->
        {:reply, {:ok, request.ref, request.id, request.task_augmented?}, state}

      {:error, error, state} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel_request, ref, reason}, _from, state) do
    case Outbound.cancel(state, ref, reason) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:disown_task, task_id}, state),
    do: {:noreply, TaskRegistry.disown(state, task_id)}

  ## Messages

  @impl true
  def handle_info({:http, ref, event}, state), do: {:noreply, http_event(state, ref, event)}

  def handle_info({:session_stream, ref, event}, %{session_stream: %{ref: ref}} = state),
    do: {:noreply, SessionStream.event(state, event)}

  def handle_info({:session_stream, _stale_ref, {:started, http_ref}}, state) do
    HTTP.cancel(http_ref)
    {:noreply, state}
  end

  def handle_info({:session_stream, _stale_ref, _event}, state), do: {:noreply, state}

  def handle_info({:session_recovery_complete, generation, result}, state),
    do: {:noreply, Recovery.finish(state, generation, result, &replay/2)}

  def handle_info({:stale_session_detected, %Error{}, stale_session_id, generation}, state) do
    lifecycle = state.lifecycle

    if lifecycle.phase == :initialized and generation == lifecycle.session_generation and
         stale_session_id == lifecycle.session_id,
       do: {:noreply, Recovery.begin(state, nil)},
       else: {:noreply, state}
  end

  def handle_info({:reconnect_subscription, ref}, state) do
    case Outbound.fetch(state, ref) do
      {:ok, %Request{subscription: %{}, worker: nil, http_ref: nil} = request} ->
        {:noreply, Outbound.reopen(state, request)}

      _stale_active_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, ref}, state), do: {:noreply, Outbound.timed_out(state, ref)}

  def handle_info({:ready_timeout, from}, state) do
    error = readiness_timeout_error(:deadline)
    {:noreply, Lifecycle.drop_waiter(state, from, {:error, error})}
  end

  def handle_info({:responded, _ref, :stop, :ok}, state), do: {:stop, :normal, state}

  def handle_info({:responded, ref, then, result}, state),
    do: {:noreply, CallbackTasks.responded(state, ref, then, result)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} -> {:noreply, state}
      {tag, monitors} -> {:noreply, down(tag, reason, %{state | monitors: monitors})}
    end
  end

  def handle_info({:task_wait_timeout, task_id, ref}, state) do
    case TaskRegistry.pop_waiter(state.tasks, task_id, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {waiter, tasks} ->
        GenServer.reply(waiter.from, :timeout)
        {:noreply, %{state | tasks: tasks}}
    end
  end

  def handle_info({:callback_request_complete, id, result}, state),
    do: {:noreply, CallbackTasks.request_complete(state, id, result)}

  def handle_info({:callback_task_complete, task_id, result}, state),
    do: {:noreply, CallbackTasks.task_complete(state, task_id, result)}

  def handle_info({port, {:data, data}}, %{transport: %{type: :stdio, port: port}} = state),
    do: transport_data(state, data)

  def handle_info(
        {:fastest_mcp_transport_data, coordinator, data},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      )
      when is_binary(data),
      do: transport_data(state, data)

  def handle_info(
        {port, {:exit_status, status}},
        %{transport: %{type: :stdio, port: port}} = state
      ),
      do: noreply_or_stop(Stdio.exited(state, status))

  def handle_info(
        {:fastest_mcp_transport_closed, coordinator, reason},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      ) do
    error = %Error{
      code: :internal_error,
      message: "in-process client transport closed",
      details: %{reason: inspect(reason)}
    }

    {:stop, :normal, Stdio.fail(state, error)}
  end

  def handle_info({:restart_stdio_transport, token}, %{stdio: %{restarting: token}} = state),
    do: noreply_or_stop(Stdio.restart(state))

  def handle_info({:restart_stdio_transport, _stale_token}, state), do: {:noreply, state}

  def handle_info(:oauth_credentials_refreshed, state), do: {:noreply, rotate_auth(state)}

  # The connection traps exits so supervisor shutdown runs terminate/2. Port
  # exits are handled through transport messages; an abnormal exit of a linked
  # helper (worker supervisor, OAuth, in-process transport) still stops us.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp transport_data(state, data) do
    case Stdio.data(state, data) do
      {:ok, state} -> {:noreply, state}
      {:error, error, state} -> {:stop, :normal, Stdio.fail(state, error)}
    end
  end

  defp noreply_or_stop({:ok, state}), do: {:noreply, state}
  defp noreply_or_stop({:stop, state}), do: {:stop, :normal, state}

  defp replay({from, call}, state) do
    case handle_call(call, from, state) do
      {:reply, reply, state} ->
        GenServer.reply(from, reply)
        state

      {:noreply, state} ->
        state
    end
  end

  defp retire_transport(%{transport: %{type: :stdio}} = state), do: Stdio.retire(state)

  defp retire_transport(state) do
    case ClientTransport.close(state.transport) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  ## Monitors

  defp down({:owner, ref}, _reason, state) do
    case Outbound.fetch(state, ref) do
      # It may still create a task, which its owner's exit then cancels.
      {:ok, %Request{spec: %Spec{owns_task?: true}} = request} ->
        Outbound.put(state, %{request | owner_ref: nil})

      {:ok, request} ->
        Outbound.cancelled(state, request, "request owner exited")

      :error ->
        state
    end
  end

  # A running task's owner exited before its call returned. The task is
  # cancelled fire-and-forget, within the 5 s a cancelled tool call allows.
  defp down({:task_owner, task_id}, _reason, state) do
    unless TaskRegistry.terminal?(TaskRegistry.fetch(state.tasks, task_id).status) do
      client = %Client{pid: self()}

      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        RemoteTasks.cancel(client, task_id, timeout_ms: 5_000)
      end)
    end

    TaskRegistry.disown(state, task_id)
  end

  defp down({:worker, ref}, reason, state) do
    Outbound.finish(
      state,
      ref,
      {:error,
       %Error{
         code: :internal_error,
         message: "client request worker crashed",
         details: %{reason: inspect(reason)}
       }}
    )
  end

  defp down(:negotiation, _reason, state) do
    case state.lifecycle.negotiation do
      %{kind: :initialize} -> failed_initialize(state)
      %{kind: :discover, token: token} -> failed_discover(state, token)
      nil -> state
    end
  end

  defp down({:ready_waiter, from}, _reason, state), do: Lifecycle.drop_waiter(state, from, nil)
  defp down(:recovery, reason, state), do: Recovery.down(state, reason)
  defp down(:catalog_loader, reason, state), do: Catalog.loader_down(state, reason)
  defp down(:session_stream, reason, state), do: SessionStream.down(state, reason)
  defp down({:callback, id}, reason, state), do: CallbackTasks.request_down(state, id, reason)
  defp down({:callback_task, id}, reason, state), do: CallbackTasks.task_down(state, id, reason)
  defp down(:dispatcher, _reason, state), do: start_dispatcher(state)

  ## Lifecycle

  defp negotiating(state, owner) do
    {ref, state} = State.monitor(state, owner, :negotiation)
    put_in(state.lifecycle.negotiation[:owner_ref], ref)
  end

  # A finished negotiation releases its owner and the readiness waiters; a new
  # protocol version or server drops the caches.
  defp negotiated(state, {:ok, lifecycle}) do
    previous = state.lifecycle
    state = State.demonitor(%{state | lifecycle: lifecycle}, previous.negotiation[:owner_ref])

    state =
      if previous.protocol_version != lifecycle.protocol_version or
           previous.server_identity != lifecycle.server_identity,
         do: Catalog.invalidate(state, :connection_identity_changed),
         else: state

    {:reply, :ok, Lifecycle.release(state)}
  end

  defp negotiated(state, {:error, error}), do: {:reply, {:error, error}, state}

  defp failed_initialize(state) do
    owner_ref = state.lifecycle.negotiation[:owner_ref]
    lifecycle = Lifecycle.fail_initialize(state.lifecycle)
    state = State.demonitor(%{state | lifecycle: lifecycle}, owner_ref)
    Lifecycle.reply_waiters(state, {:error, Lifecycle.readiness_error(lifecycle)})
  end

  defp failed_discover(state, token) do
    case Lifecycle.fail_discover(state.lifecycle, token) do
      {:ok, lifecycle} ->
        State.demonitor(%{state | lifecycle: lifecycle}, state.lifecycle.negotiation[:owner_ref])

      :stale ->
        state
    end
  end

  defp rotate_auth(state) do
    state
    |> update_in([Access.key(:lifecycle), Access.key(:auth_generation)], &(&1 + 1))
    |> Catalog.invalidate(:authentication_changed)
  end

  # Notifications the connection sends itself report a stale HTTP session.
  defp own_notify(state, method, params, opts),
    do: Outbound.notify(TransportSnapshot.new(state, true), method, params, opts)

  ## HTTP events

  # A tracked request's worker reports its HTTP handle, server messages from
  # its response stream, and its result. Session recovery runs untracked
  # requests (ref nil) that keep their handle to themselves.
  defp http_event(state, nil, {:started, _http_ref}), do: state

  defp http_event(state, ref, {:started, http_ref}) do
    case Outbound.fetch(state, ref) do
      {:ok, %Request{worker: pid} = request} when is_pid(pid) ->
        if request.http_ref not in [nil, http_ref], do: HTTP.cancel(request.http_ref)
        Outbound.put(state, %{request | http_ref: http_ref})

      _stale_or_unknown_request ->
        HTTP.cancel(http_ref)
        state
    end
  end

  defp http_event(state, _ref, {:notification, message}), do: Notifications.route(state, message)

  # A server request whose answer cannot be delivered fails this request.
  defp http_event(state, ref, {:server_request, message}) do
    origin =
      case Outbound.fetch(state, ref) do
        {:ok, request} -> request
        :error -> nil
      end

    CallbackTasks.handle(state, message, origin)
  end

  defp http_event(
         state,
         ref,
         {:done, {:missing_session, %Error{} = error, session_id, generation}}
       ) do
    case Outbound.take(state, ref) do
      {nil, state} ->
        state

      {request, state} ->
        if generation == state.lifecycle.session_generation and
             session_id == state.lifecycle.session_id do
          Recovery.begin(state, {:request, request, error})
        else
          Outbound.reply(request, {:error, Recovery.not_replayed(error)})
          state
        end
    end
  end

  defp http_event(state, ref, {:done, {:modern_subscription_terminated, %Error{} = error, delay}}) do
    case Outbound.fetch(state, ref) do
      {:ok, %Request{subscription: %{}} = request} ->
        Outbound.detach(state, request, error, delay)

      _stale_or_cancelled_request ->
        state
    end
  end

  defp http_event(state, ref, {:done, result}), do: Outbound.complete(state, ref, result)
end
