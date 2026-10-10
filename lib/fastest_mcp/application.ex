defmodule FastestMCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: FastestMCP.TaskSupervisor},
      FastestMCP.Registry,
      {Registry, keys: :duplicate, name: FastestMCP.PubSub},
      FastestMCP.ServerSupervisor,
      FastestMCP.Transport.Stdio.OutputGuard
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: FastestMCP.Supervisor)
  end
end
