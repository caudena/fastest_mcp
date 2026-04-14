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

  alias FastestMCP.Auth.StateStore
  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.BackgroundTaskSupervisor
  alias FastestMCP.CallSupervisor
  alias FastestMCP.ComponentManager
  alias FastestMCP.ComponentVisibility
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
  alias FastestMCP.SessionSupervisor

  @doc "Starts the runtime or application process owned by this module."
  def start(%Server{} = server, opts \\ []) do
    FastestMCP.ServerSupervisor.start_server(server, opts)
  end

  @doc "Stops the runtime process identified by the given server name."
  def stop(server_name) do
    case Registry.lookup_server_owner(server_name) do
      {:ok, owner_pid} ->
        Supervisor.stop(owner_pid, :shutdown)

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

  @doc "Starts the process owned by this module."
  def start_link({%Server{} = server, opts}) do
    GenServer.start_link(__MODULE__, {server, opts})
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({%Server{} = server, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, lifespan_context, lifespan_cleanups} <- Lifespan.run_all(server, server.lifespans) do
      {:ok, component_manager_pid} =
        ComponentManager.start_link(server_name: server.name, on_duplicate: server.on_duplicate)

      component_manager = ComponentManager.new(server.name, component_manager_pid)

      server =
        %{server | providers: server.providers ++ [Provider.new(component_manager)]}
        |> materialize_server_runtime()

      {:ok, session_state_store} = start_session_state_store(opts)

      {:ok, session_supervisor} =
        SessionSupervisor.start_link(
          max_sessions: max_sessions(opts),
          session_idle_ttl: session_idle_ttl(opts),
          session_state_store: session_state_store
        )

      {:ok, terminated_session_store} =
        StateStore.start_link(ttl_ms: terminated_session_ttl(opts))

      {:ok, call_supervisor} =
        CallSupervisor.start_link(max_children: max_concurrent_calls(opts))

      {:ok, event_bus} =
        EventBus.start_link(
          max_server_subscribers: max_event_subscribers_per_server(opts),
          max_all_subscribers: max_global_event_subscribers(opts),
          max_subscriber_queue_len: max_event_subscriber_queue_len(opts)
        )

      {:ok, task_supervisor} =
        BackgroundTaskSupervisor.start_link(max_children: max_background_tasks(opts))

      {:ok, task_backend} = start_task_backend(opts)

      {:ok, task_store} =
        BackgroundTaskStore.start_link(
          server_name: server.name,
          event_bus: event_bus,
          backend: task_backend,
          mask_error_details: server.mask_error_details
        )

      {:ok, task_notification_supervisor} =
        TaskNotificationSupervisor.start_link()

      {:ok, session_notification_supervisor} =
        SessionNotificationSupervisor.start_link()

      {:ok, oauth_state_store} = StateStore.start_link(ttl_ms: oauth_state_ttl(opts))
      {:ok, client_request_store} = StateStore.start_link(ttl_ms: client_request_ttl(opts))
      {:ok, session_stream_store} = StateStore.start_link(ttl_ms: :infinity)
      {:ok, oauth_client_store} = StateStore.start_link(ttl_ms: :infinity)

      {:ok, oauth_authorization_code_store} =
        StateStore.start_link(ttl_ms: oauth_authorization_code_ttl(opts))

      access_token_ttl_ms = oauth_access_token_ttl(opts)
      {:ok, oauth_access_token_store} = StateStore.start_link(ttl_ms: access_token_ttl_ms)

      refresh_token_ttl_ms = oauth_refresh_token_ttl(opts)
      {:ok, oauth_refresh_token_store} = StateStore.start_link(ttl_ms: refresh_token_ttl_ms)

      Registry.register_server(server.name, self())
      Registry.register_components(server.name, Server.all_components(server))

      {:ok,
       %{
         server: server,
         opts: opts,
         component_manager: component_manager,
         session_state_store: session_state_store,
         session_supervisor: session_supervisor,
         terminated_session_store: terminated_session_store,
         call_supervisor: call_supervisor,
         task_supervisor: task_supervisor,
         task_store: task_store,
         task_notification_supervisor: task_notification_supervisor,
         session_notification_supervisor: session_notification_supervisor,
         event_bus: event_bus,
         lifespan_context: lifespan_context,
         lifespan_cleanups: lifespan_cleanups,
         client_request_store: client_request_store,
         session_stream_store: session_stream_store,
         oauth_state_store: oauth_state_store,
         oauth_client_store: oauth_client_store,
         oauth_authorization_code_store: oauth_authorization_code_store,
         oauth_access_token_store: oauth_access_token_store,
         oauth_refresh_token_store: oauth_refresh_token_store,
         oauth_access_token_ttl_ms: access_token_ttl_ms,
         oauth_refresh_token_ttl_ms: refresh_token_ttl_ms
       }}
    else
      {:error, reason} ->
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
  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    {:stop, {:linked_process_exit, pid, reason}, state}
  end

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    shutdown_server_runtime(Map.get(state, :server))
    Lifespan.cleanup_all(Map.get(state, :lifespan_cleanups, []))
    Registry.unregister_server(state.server.name)
    ComponentVisibility.delete(state.server.name)
    :ok
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

  defp oauth_state_ttl(opts) do
    case Keyword.get(opts, :oauth_state_ttl, 5 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "oauth_state_ttl must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp oauth_authorization_code_ttl(opts) do
    case Keyword.get(opts, :oauth_authorization_code_ttl, 5 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "oauth_authorization_code_ttl must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp oauth_access_token_ttl(opts) do
    case Keyword.get(opts, :oauth_access_token_ttl, 60 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "oauth_access_token_ttl must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp oauth_refresh_token_ttl(opts) do
    case Keyword.get(opts, :oauth_refresh_token_ttl, :infinity) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "oauth_refresh_token_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp materialize_server_runtime(%Server{} = server) do
    %{
      server
      | middleware: Enum.map(server.middleware, &Middleware.activate_runtime/1),
        providers: Enum.map(server.providers, &materialize_provider_runtime/1)
    }
  end

  defp materialize_provider_runtime(%Provider{} = provider) do
    %{provider | inner: materialize_provider_inner(provider.inner)}
  end

  defp materialize_provider_runtime(provider), do: provider

  defp materialize_provider_inner(%MountedServer{} = provider) do
    %{provider | server: materialize_server_runtime(provider.server)}
  end

  defp materialize_provider_inner(%module{} = provider) do
    if function_exported?(module, :activate_runtime, 1) do
      module.activate_runtime(provider)
    else
      provider
    end
  end

  defp shutdown_server_runtime(nil), do: :ok

  defp shutdown_server_runtime(%Server{} = server) do
    Enum.each(server.middleware, &Middleware.deactivate_runtime/1)
    Enum.each(server.providers, &shutdown_provider_runtime/1)
  end

  defp shutdown_provider_runtime(%Provider{} = provider) do
    shutdown_provider_runtime(provider.inner)
  end

  defp shutdown_provider_runtime(%MountedServer{} = provider) do
    shutdown_server_runtime(provider.server)
  end

  defp shutdown_provider_runtime(%module{} = provider) do
    if function_exported?(module, :deactivate_runtime, 1) do
      module.deactivate_runtime(provider)
    else
      :ok
    end
  end

  defp shutdown_provider_runtime(_provider), do: :ok
end
