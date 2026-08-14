defmodule FastestMCP.Client.Transport.InProcess.ConnectionSupervisor do
  @moduledoc false

  use Supervisor

  alias FastestMCP.Client.Transport.InProcess.Coordinator

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def coordinator(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{Coordinator, coordinator, :worker, [Coordinator]}] when is_pid(coordinator) ->
        {:ok, coordinator}

      _children ->
        {:error, :coordinator_not_started}
    end
  end

  @impl true
  def init(opts) do
    Supervisor.init([{Coordinator, opts}], strategy: :one_for_one)
  end
end
