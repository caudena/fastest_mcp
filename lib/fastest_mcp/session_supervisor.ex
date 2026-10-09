defmodule FastestMCP.SessionSupervisor do
  @moduledoc false
  # Supervises one server's session processes, bounded by `max_sessions`.
  # Sessions register their own names, so starting an existing session returns
  # the running process.

  use DynamicSupervisor

  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.ServerRuntime.Lifecycle
  alias FastestMCP.Session

  def start_link({server_name, config}) do
    DynamicSupervisor.start_link(__MODULE__, {server_name, config},
      name: Registry.via({:sessions, server_name})
    )
  end

  @impl true
  def init({server_name, config}) do
    info = Lifecycle.info(server_name)

    session_opts =
      config
      |> Config.session_opts()
      |> Map.merge(%{
        session_state_store: info.session_state_store,
        runtime_quota: info.runtime_quota,
        task_supervisor: GenServer.whereis(Registry.via({:stream_tasks, server_name})),
        event_bus: ServerRuntime.event_bus(config)
      })

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: config.max_sessions,
      extra_arguments: [session_opts]
    )
  end

  def ensure_session(supervisor, server_name, session_id) do
    with {:error, :not_found} <- Registry.lookup_session(server_name, session_id) do
      case DynamicSupervisor.start_child(supervisor, {Session, {server_name, session_id}}) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, :max_children} -> {:error, :overloaded}
        other -> other
      end
    end
  end

  # Deletes the session's stored state before stopping it.
  def terminate_session(server_name, session_id) do
    await_queued_starts(server_name)
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id), do: Session.close(pid)
  end

  # A request killed while starting a session left that start queued here, and
  # the session would outlive its termination; the start has run once the
  # supervisor answered a later call.
  defp await_queued_starts(server_name) do
    DynamicSupervisor.count_children(Registry.via({:sessions, server_name}))
  catch
    :exit, _reason -> :ok
  end
end
