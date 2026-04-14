defmodule FastestMCP.Application do
  @moduledoc """
  Starts the shared OTP application tree used by FastestMCP.

  The library keeps a small set of global processes alive for the whole
  application: the registry used for lookups and the dynamic supervisor used
  to own started server runtimes.

  Applications normally do not call this module directly. It exists so Mix
  applications that depend on FastestMCP get the required runtime services
  started before any server, transport, or client process asks for them.
  """

  use Application

  @impl true
  @doc "Starts the runtime or application process owned by this module."
  def start(_type, _args) do
    children = [
      FastestMCP.Registry,
      FastestMCP.ServerSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FastestMCP.Supervisor)
  end
end
