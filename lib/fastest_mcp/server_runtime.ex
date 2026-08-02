defmodule FastestMCP.ServerRuntime do
  @moduledoc ~S"""
  Core runtime process for one running server.

  `FastestMCP.ServerRuntime` is the process that turns an immutable
  `%FastestMCP.Server{}` into a live system. During startup it assembles the
  server-local OTP pieces that the rest of the runtime depends on, including:

    * the live `FastestMCP.ComponentManager`
    * session supervision
    * background task supervision and storage
    * call isolation
    * the event bus
    * OAuth-related state stores
    * lifespan enter and cleanup hooks

  This module is intentionally internal. Most users should think in terms of
  `FastestMCP.start_server/2` and `FastestMCP.ServerModule`. This file matters
  when you need to understand what "a running server" actually means inside the
  system.
  """

  use GenServer

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.BackgroundTaskSupervisor
  alias FastestMCP.CallSupervisor
  alias FastestMCP.ComponentManager
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.EventBus
  alias FastestMCP.Lifespan
  alias FastestMCP.Middleware
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer
  alias FastestMCP.Registry
  alias FastestMCP.Server
  alias FastestMCP.SessionNotificationSupervisor
  alias FastestMCP.SessionStateStore.Memory, as: SessionStateStoreMemory
  alias FastestMCP.TaskBackend.Memory, as: MemoryTaskBackend
  alias FastestMCP.TaskNotificationSupervisor
  alias FastestMCP.TTLStore
  alias FastestMCP.SessionSupervisor

  @session_stream_owner_ttl_ms 90_000

  @doc "Starts the runtime or application process owned by this module."
  def start(%Server{} = server, opts \\ []) do
    FastestMCP.ServerSupervisor.start_server(server, opts)
  end

  @doc "Stops the runtime process identified by the given server name."
  def stop(server_name) do
    case Registry.lookup_server_owner(server_name) do
      {:ok, owner_pid} ->
        case FastestMCP.ServerSupervisor.stop_server(owner_pid) do
          :ok -> :ok
          {:error, :not_found} -> Supervisor.stop(owner_pid, :shutdown)
          other -> other
        end

      {:error, :not_found} ->
        with {:ok, pid} <- Registry.lookup_server(server_name) do
          case FastestMCP.ServerSupervisor.stop_server(pid) do
            :ok -> :ok
            {:error, :not_found} -> GenServer.stop(pid, :shutdown)
            other -> other
          end
        end
    end
  end

  @doc "Fetches the latest state managed by this module."
  def fetch(server_name) do
    with {:ok, pid} <- Registry.lookup_server(server_name) do
      GenServer.call(pid, :fetch)
    end
  end

  @doc "Builds Context options from one runtime, inheriting a same-server current context."
  def context_opts(runtime, opts \\ []) when is_map(runtime) and is_list(opts) do
    opts
    |> maybe_inherit_context(runtime.server.name)
    |> Keyword.merge(
      server: runtime.server,
      dependencies: runtime.server.dependencies,
      task_store: Map.get(runtime, :task_store),
      session_supervisor: runtime.session_supervisor,
      terminated_session_store: Map.get(runtime, :terminated_session_store),
      event_bus: runtime.event_bus,
      lifespan_context: Map.get(runtime, :lifespan_context, %{})
    )
  end

  @doc "Starts the process owned by this module."
  def start_link({%Server{} = server, opts}) do
    GenServer.start_link(__MODULE__, {server, opts})
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({%Server{} = server, opts}) do
    Process.flag(:trap_exit, true)

    initial = %{server: server, opts: opts, rollback: []}

    case start_runtime(initial) do
      {:ok, state} ->
        {:ok, Map.delete(state, :rollback)}

      {:error, reason, state} ->
        rollback(state)
        {:stop, reason}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call(:fetch, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info(
        {:DOWN, monitor, :process, registry_pid, reason},
        %{registry_monitor: monitor, registry_pid: registry_pid} = state
      ) do
    {:stop, {:registry_replaced, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    {:stop, {:linked_process_exit, pid, reason}, state}
  end

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(reason, state) do
    cleanup_steps([
      fn -> demonitor_registry(state) end,
      fn -> terminate_session_streams(state) end,
      fn -> drain_sessions(state, reason) end,
      fn -> shutdown_server_runtime(Map.get(state, :server)) end,
      fn -> Lifespan.cleanup_all(Map.get(state, :lifespan_cleanups, [])) end,
      fn -> Registry.unregister_server(state.server.name, self()) end,
      fn -> ComponentVisibility.delete(state.server.name) end
    ])

    :ok
  end

  defp start_runtime(initial) do
    with {:ok, state} <- monitor_registry(initial),
         {:ok, state} <- claim_server_owner(state),
         {:ok, state} <- claim_server(state),
         {:ok, state} <- start_lifespans(state),
         {:ok, state} <- start_component_manager(state),
         {:ok, state} <- materialize_runtime(state),
         {:ok, state} <- start_session_state_store_step(state),
         {:ok, state} <- start_session_supervisor_step(state),
         {:ok, state} <- start_terminated_session_store(state),
         {:ok, state} <- start_call_supervisor(state),
         {:ok, state} <- start_stream_task_supervisor(state),
         {:ok, state} <- start_event_bus(state),
         {:ok, state} <- start_task_supervisor(state),
         {:ok, state} <- start_task_backend_step(state),
         {:ok, state} <- start_task_store(state),
         {:ok, state} <- start_task_notification_supervisor(state),
         {:ok, state} <- start_session_notification_supervisor(state),
         {:ok, state} <- start_client_request_store(state),
         {:ok, state} <- start_session_stream_store(state),
         {:ok, state} <- register_components(state) do
      {:ok, state}
    end
  end

  defp claim_server_owner(%{opts: opts} = state) do
    case Keyword.get(opts, :server_owner_pid) do
      owner_pid when is_pid(owner_pid) ->
        case safe_start(fn -> Registry.acquire_server_owner(state.server.name, owner_pid) end) do
          {:ok, {:ok, :existing}} ->
            {:ok, state}

          {:ok, {:ok, :acquired}} ->
            {:ok,
             add_rollback(state, fn ->
               Registry.unregister_server_owner(state.server.name, owner_pid)
             end)}

          {:ok, {:error, reason}} ->
            {:error, reason, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      _other ->
        {:ok, state}
    end
  end

  defp monitor_registry(state) do
    case Process.whereis(Registry) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)

        {:ok,
         state
         |> Map.put(:registry_pid, pid)
         |> Map.put(:registry_monitor, monitor)
         |> add_rollback(fn -> Process.demonitor(monitor, [:flush]) end)}

      nil ->
        {:error, :registry_not_running, state}
    end
  end

  defp claim_server(state) do
    case safe_start(fn -> Registry.register_server(state.server.name, self()) end) do
      {:ok, :ok} ->
        {:ok,
         add_rollback(state, fn -> Registry.unregister_server(state.server.name, self()) end)}

      {:ok, {:error, reason}} ->
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_lifespans(state) do
    case safe_start(fn -> Lifespan.run_all(state.server, state.server.lifespans) end) do
      {:ok, {:ok, context, cleanups}} ->
        {:ok,
         state
         |> Map.put(:lifespan_context, context)
         |> Map.put(:lifespan_cleanups, cleanups)
         |> add_rollback(fn -> Lifespan.cleanup_all(cleanups) end)}

      {:ok, {:error, reason}} ->
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_component_manager(state) do
    result =
      safe_start(fn ->
        ComponentManager.start_link(
          server_name: state.server.name,
          on_duplicate: state.server.on_duplicate
        )
      end)

    case result do
      {:ok, {:ok, pid}} ->
        manager = ComponentManager.new(state.server.name, pid)

        {:ok,
         state
         |> Map.put(:component_manager, manager)
         |> add_rollback(fn -> stop_started_process(pid) end)}

      {:ok, {:error, reason}} ->
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp materialize_runtime(state) do
    server = %{
      state.server
      | providers: state.server.providers ++ [Provider.new(state.component_manager)]
    }

    case safe_start(fn -> materialize_server_runtime(server) end) do
      {:ok, {:ok, materialized}} ->
        {:ok,
         state
         |> Map.put(:server, materialized)
         |> add_rollback(fn -> shutdown_server_runtime(materialized) end)}

      {:ok, {:error, reason}} ->
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp start_session_state_store_step(state) do
    start_process_step(
      state,
      :session_state_store,
      fn -> start_session_state_store(state.opts) end,
      pid: & &1.store
    )
  end

  defp start_session_supervisor_step(state) do
    start_process_step(state, :session_supervisor, fn ->
      SessionSupervisor.start_link(
        max_sessions: max_sessions(state.opts),
        session_idle_ttl: session_idle_ttl(state.opts),
        session_state_store: state.session_state_store
      )
    end)
  end

  defp start_terminated_session_store(state) do
    start_process_step(state, :terminated_session_store, fn ->
      TTLStore.start_link(ttl_ms: terminated_session_ttl(state.opts))
    end)
  end

  defp start_call_supervisor(state) do
    start_process_step(state, :call_supervisor, fn ->
      CallSupervisor.start_link(max_children: max_concurrent_calls(state.opts))
    end)
  end

  defp start_stream_task_supervisor(state) do
    start_process_step(state, :stream_task_supervisor, &Task.Supervisor.start_link/0)
  end

  defp start_event_bus(state) do
    start_process_step(state, :event_bus, fn ->
      EventBus.start_link(
        max_server_subscribers: max_event_subscribers_per_server(state.opts),
        max_all_subscribers: max_global_event_subscribers(state.opts),
        max_subscriber_queue_len: max_event_subscriber_queue_len(state.opts)
      )
    end)
  end

  defp start_task_supervisor(state) do
    start_process_step(state, :task_supervisor, fn ->
      BackgroundTaskSupervisor.start_link(max_children: max_background_tasks(state.opts))
    end)
  end

  defp start_task_backend_step(state) do
    start_process_step(state, :task_backend, fn -> start_task_backend(state.opts) end,
      pid: & &1.store
    )
  end

  defp start_task_store(state) do
    start_process_step(state, :task_store, fn ->
      BackgroundTaskStore.start_link(
        server_name: state.server.name,
        event_bus: state.event_bus,
        backend: state.task_backend,
        mask_error_details: state.server.mask_error_details
      )
    end)
  end

  defp start_task_notification_supervisor(state) do
    start_process_step(
      state,
      :task_notification_supervisor,
      &TaskNotificationSupervisor.start_link/0
    )
  end

  defp start_session_notification_supervisor(state) do
    start_process_step(
      state,
      :session_notification_supervisor,
      &SessionNotificationSupervisor.start_link/0
    )
  end

  defp start_client_request_store(state) do
    start_process_step(state, :client_request_store, fn ->
      TTLStore.start_link(ttl_ms: client_request_ttl(state.opts))
    end)
  end

  defp start_session_stream_store(state) do
    start_process_step(state, :session_stream_store, fn ->
      TTLStore.start_link(ttl_ms: @session_stream_owner_ttl_ms)
    end)
  end

  defp register_components(state) do
    case safe_start(fn ->
           Registry.register_components(state.server.name, Server.all_components(state.server))
         end) do
      {:ok, :ok} -> {:ok, state}
      {:ok, {:error, reason}} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_process_step(state, key, start_fun, opts \\ []) do
    case safe_start(start_fun) do
      {:ok, {:ok, value}} ->
        pid = Keyword.get(opts, :pid, &Function.identity/1).(value)

        {:ok,
         state
         |> Map.put(key, value)
         |> add_rollback(fn -> stop_started_process(pid) end)}

      {:ok, {:error, reason}} ->
        {:error, reason, state}

      {:ok, other} ->
        {:error, {:invalid_start_result, key, other}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp safe_start(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp add_rollback(state, cleanup), do: Map.update!(state, :rollback, &[cleanup | &1])

  defp rollback(state) do
    cleanup_steps(Map.get(state, :rollback, []))
  end

  defp cleanup_steps(cleanups), do: Enum.each(cleanups, &safe_cleanup/1)

  defp safe_cleanup(cleanup) do
    _ = cleanup.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stop_started_process(pid) when is_pid(pid) do
    Process.unlink(pid)

    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp demonitor_registry(%{registry_monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp demonitor_registry(_state), do: :ok

  defp maybe_inherit_context(opts, server_name) do
    case Context.current() do
      %Context{server_name: ^server_name} = context ->
        opts
        |> maybe_put_opt(:session_id, context.session_id)
        |> maybe_put_opt(:transport, context.transport)
        |> maybe_put_opt(:state_scope, context.state_scope)
        |> maybe_put_opt(:negotiated_protocol_version, context.negotiated_protocol_version)
        |> maybe_put_opt(:client_capabilities, context.client_capabilities)
        |> maybe_put_opt(:request_metadata, context.request_metadata)
        |> maybe_put_opt(:auth_input, inherited_auth_input(context))
        |> maybe_put_opt(:principal, context.principal)
        |> maybe_put_opt(:auth, context.auth)
        |> maybe_put_opt(:capabilities, context.capabilities)

      _other ->
        opts
    end
  end

  defp inherited_auth_input(%Context{} = context) do
    request_metadata = Map.new(context.request_metadata)
    access_token = Context.access_token(context)

    headers =
      request_metadata
      |> Map.get(:headers, Map.get(request_metadata, "headers", %{}))
      |> Map.new()

    has_authorization? =
      Map.has_key?(headers, "authorization") or
        Map.has_key?(headers, :authorization) or
        Map.has_key?(request_metadata, "authorization") or
        Map.has_key?(request_metadata, :authorization)

    if access_token && not has_authorization? do
      request_metadata
      |> Map.put("headers", Map.put(headers, "authorization", "Bearer " <> access_token))
      |> Map.put_new("authorization", "Bearer " <> access_token)
    else
      request_metadata
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts

  defp maybe_put_opt(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end

  defp max_concurrent_calls(opts) do
    case Keyword.get(opts, :max_concurrent_calls, :infinity) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_concurrent_calls must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_sessions(opts) do
    case Keyword.get(opts, :max_sessions, 10_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_sessions must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_background_tasks(opts) do
    case Keyword.get(opts, :max_background_tasks, :infinity) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_background_tasks must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp session_idle_ttl(opts) do
    case Keyword.get(opts, :session_idle_ttl, 15 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "session_idle_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp terminated_session_ttl(opts) do
    case Keyword.get(opts, :terminated_session_ttl, 15 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "terminated_session_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp start_session_state_store(opts) do
    {module, store_opts} = session_state_store_config(opts)

    case module.start_link(store_opts) do
      {:ok, store} -> {:ok, %{module: module, store: store}}
      other -> other
    end
  end

  defp start_task_backend(opts) do
    {module, backend_opts} = task_backend_config(opts)

    case module.start_link(backend_opts) do
      {:ok, store} -> {:ok, %{module: module, store: store}}
      other -> other
    end
  end

  defp task_backend_config(opts) do
    case Keyword.get(opts, :task_backend, {MemoryTaskBackend, []}) do
      {module, backend_opts} when is_atom(module) and is_list(backend_opts) ->
        {module, backend_opts}

      module when is_atom(module) ->
        {module, []}

      other ->
        raise ArgumentError,
              "task_backend must be a module or {module, opts}, got: #{inspect(other)}"
    end
  end

  defp session_state_store_config(opts) do
    case Keyword.get(opts, :session_state_store, {SessionStateStoreMemory, []}) do
      {module, store_opts} when is_atom(module) and is_list(store_opts) ->
        {module, store_opts}

      module when is_atom(module) ->
        {module, []}

      other ->
        raise ArgumentError,
              "session_state_store must be a module or {module, opts}, got: #{inspect(other)}"
    end
  end

  defp max_event_subscribers_per_server(opts) do
    case Keyword.get(opts, :max_event_subscribers_per_server, 1_024) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_event_subscribers_per_server must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp client_request_ttl(opts) do
    case Keyword.get(opts, :client_request_ttl, 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "client_request_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_global_event_subscribers(opts) do
    case Keyword.get(opts, :max_global_event_subscribers, 128) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_global_event_subscribers must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_event_subscriber_queue_len(opts) do
    case Keyword.get(opts, :max_event_subscriber_queue_len, 100) do
      value when is_integer(value) and value >= 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_event_subscriber_queue_len must be a non-negative integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp materialize_server_runtime(%Server{} = server) do
    case materialize_provider_runtimes(server.providers) do
      {:ok, providers} ->
        case materialize_middleware_runtimes(server.middleware) do
          {:ok, middleware} ->
            {:ok, %{server | middleware: middleware, providers: providers}}

          {:error, reason} ->
            providers |> Enum.reverse() |> Enum.each(&safe_shutdown_provider_runtime/1)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp materialize_middleware_runtimes(middleware) do
    Enum.reduce_while(middleware, {:ok, []}, fn item, {:ok, acc} ->
      case safe_start(fn -> Middleware.activate_runtime(item) end) do
        {:ok, activated} ->
          {:cont, {:ok, [activated | acc]}}

        {:error, reason} ->
          Enum.each(acc, &safe_deactivate_middleware_runtime/1)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, materialized} -> {:ok, Enum.reverse(materialized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_provider_runtimes(providers) do
    Enum.reduce_while(providers, {:ok, []}, fn provider, {:ok, acc} ->
      case materialize_provider_runtime(provider) do
        {:ok, materialized} -> {:cont, {:ok, [materialized | acc]}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
    |> case do
      {:ok, providers} ->
        {:ok, Enum.reverse(providers)}

      {:error, reason, materialized} ->
        Enum.each(materialized, &safe_shutdown_provider_runtime/1)
        {:error, reason}
    end
  end

  defp materialize_provider_runtime(%Provider{} = provider) do
    case safe_start(fn -> materialize_provider_inner(provider.inner) end) do
      {:ok, {:ok, inner}} -> {:ok, %{provider | inner: inner}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_provider_runtime(provider), do: {:ok, provider}

  defp materialize_provider_inner(%MountedServer{} = provider) do
    case Lifespan.run_all(provider.server, provider.server.lifespans) do
      {:ok, lifespan_context, lifespan_cleanups} ->
        case materialize_server_runtime(provider.server) do
          {:ok, server} ->
            {:ok,
             %{
               provider
               | server: server,
                 lifespan_context: lifespan_context,
                 lifespan_cleanups: lifespan_cleanups
             }}

          {:error, reason} ->
            Lifespan.cleanup_all(lifespan_cleanups)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp materialize_provider_inner(%module{} = provider) do
    if function_exported?(module, :activate_runtime, 1) do
      case module.activate_runtime(provider) do
        {:ok, activated} -> {:ok, activated}
        {:error, reason} -> {:error, reason}
        activated -> {:ok, activated}
      end
    else
      {:ok, provider}
    end
  end

  defp materialize_provider_inner(provider), do: {:ok, provider}

  defp shutdown_server_runtime(nil), do: :ok

  defp shutdown_server_runtime(%Server{} = server) do
    server.middleware |> Enum.reverse() |> Enum.each(&safe_deactivate_middleware_runtime/1)
    server.providers |> Enum.reverse() |> Enum.each(&safe_shutdown_provider_runtime/1)
    :ok
  end

  defp safe_deactivate_middleware_runtime(middleware),
    do: safe_cleanup(fn -> Middleware.deactivate_runtime(middleware) end)

  defp safe_shutdown_provider_runtime(provider),
    do: safe_cleanup(fn -> shutdown_provider_runtime(provider) end)

  defp shutdown_provider_runtime(%Provider{} = provider) do
    shutdown_provider_runtime(provider.inner)
  end

  defp shutdown_provider_runtime(%MountedServer{} = provider) do
    shutdown_server_runtime(provider.server)
    Lifespan.cleanup_all(provider.lifespan_cleanups || [])
  end

  defp shutdown_provider_runtime(%module{} = provider) do
    if function_exported?(module, :deactivate_runtime, 1) do
      module.deactivate_runtime(provider)
    else
      :ok
    end
  end

  defp shutdown_provider_runtime(_provider), do: :ok

  defp terminate_session_streams(%{session_stream_store: store}) when is_pid(store) do
    store
    |> TTLStore.keys()
    |> Enum.each(fn session_id ->
      case TTLStore.get(store, session_id) do
        {:ok, %{owner: owner} = stream_owner} when is_pid(owner) ->
          send(owner, :session_stream_replaced)
          _ = TTLStore.delete_if(store, session_id, stream_owner)
          :ok

        _other ->
          :ok
      end
    end)
  end

  defp terminate_session_streams(_state), do: :ok

  defp drain_sessions(%{session_supervisor: supervisor}, reason) when is_pid(supervisor) do
    if orderly_shutdown_reason?(reason) and Process.alive?(supervisor) do
      SessionSupervisor.drain(supervisor)
    else
      :ok
    end
  end

  defp drain_sessions(_state, _reason), do: :ok

  defp orderly_shutdown_reason?(:shutdown), do: true
  defp orderly_shutdown_reason?({:shutdown, _reason}), do: true
  defp orderly_shutdown_reason?(_reason), do: false
end
