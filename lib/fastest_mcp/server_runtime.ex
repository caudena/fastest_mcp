defmodule FastestMCP.ServerRuntime do
  @moduledoc false
  # Supervision tree of one running server. Children restart together and stop
  # in reverse order, so sessions close before lifespans are cleaned up. Once
  # every child runs, the published `%ServerRuntime{}` snapshot is readable with
  # `fetch/1` without calling a process.

  use Supervisor

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.ComponentManager
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.Registry
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.ServerRuntime.Lifecycle
  alias FastestMCP.ServerRuntime.Publisher
  alias FastestMCP.ServerSupervisor
  alias FastestMCP.SessionSupervisor

  defstruct [
    :server,
    :config,
    :component_manager,
    :component_index,
    :schema_cache,
    :session_state_store,
    :terminated_session_store,
    :stream_task_supervisor,
    :runtime_quota,
    :call_supervisor,
    :event_bus,
    :task_supervisor,
    :task_store,
    :session_supervisor,
    :notification_supervisor,
    :pagination_cursor_secret,
    :runtime_generation,
    lifespan_context: %{},
    strict_request_ids: false
  ]

  @type t :: %__MODULE__{}

  def start(%Server{} = server, opts \\ []), do: ServerSupervisor.start_server(server, opts)

  def stop(server_name) do
    with {:error, :not_found} <- stop_process(Registry.lookup_server_owner(server_name)) do
      stop_process(Registry.lookup_server(server_name))
    end
  end

  defp stop_process({:ok, pid}) do
    with {:error, :not_found} <- ServerSupervisor.stop_server(pid),
         do: Supervisor.stop(pid, :shutdown)
  end

  defp stop_process(not_found), do: not_found

  @spec fetch(term()) :: {:ok, t()} | {:error, :not_found}
  def fetch(server_name), do: Registry.lookup_runtime(server_name)

  # `fetch/1` for public APIs: an unknown server is a `:not_found` error.
  @spec fetch_running(term()) :: {:ok, t()} | {:error, Error.t()}
  def fetch_running(server_name) do
    with {:error, :not_found} <- fetch(server_name),
         do: {:error, Error.not_found(:server, server_name)}
  end

  def start_link({%Server{} = server, opts}) do
    server = Server.prepare_for_runtime(server)
    config = Config.new!(opts)
    name = Registry.via({:server, to_string(server.name)})
    Supervisor.start_link(__MODULE__, {server, config}, name: name)
  rescue
    error -> {:error, error}
  end

  @impl true
  def init({server, config}) do
    name = to_string(server.name)
    via = &Registry.via({&1, name})

    children = [
      {ComponentManager,
       server_name: name, on_duplicate: server.on_duplicate, name: via.(:component_manager)},
      # State of stateful middleware, started by Lifecycle. Middleware holds
      # the pid it was attached to, so a crash restarts the whole runtime.
      Supervisor.child_spec({DynamicSupervisor, name: via.(:middleware), max_restarts: 0},
        id: :middleware
      ),
      {Lifecycle, {server, config}},
      Supervisor.child_spec({Task.Supervisor, name: via.(:stream_tasks)}, id: :stream_tasks),
      Supervisor.child_spec(
        {Task.Supervisor, name: via.(:calls), max_children: config.max_concurrent_calls},
        id: :calls
      ),
      Supervisor.child_spec(
        {Task.Supervisor,
         name: via.(:background_tasks), max_children: config.max_background_tasks},
        id: :background_tasks
      ),
      {BackgroundTaskStore,
       name: via.(:task_store),
       server_name: name,
       task_supervisor: via.(:background_tasks),
       event_bus: event_bus(config),
       task_backend: config.task_backend,
       relay_task_supervisor: via.(:stream_tasks),
       mask_error_details: server.mask_error_details},
      {SessionSupervisor, {name, config}},
      # Task-notification and MCP 2026 subscription subscribers.
      Supervisor.child_spec({DynamicSupervisor, name: via.(:notifications)},
        id: :notifications
      ),
      {Publisher, name}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def snapshot(server_name) do
    pid = &GenServer.whereis(Registry.via({&1, server_name}))

    info = Lifecycle.info(server_name)

    struct!(
      __MODULE__,
      Map.merge(info, %{
        stream_task_supervisor: pid.(:stream_tasks),
        call_supervisor: pid.(:calls),
        event_bus: event_bus(info.config),
        task_supervisor: pid.(:background_tasks),
        task_store: pid.(:task_store),
        session_supervisor: pid.(:sessions),
        notification_supervisor: pid.(:notifications)
      })
    )
  end

  def event_bus(config),
    do: %EventBus{
      max_subscribers: config.max_event_subscribers_per_server,
      max_queue_len: config.max_event_subscriber_queue_len
    }
end
