defmodule FastestMCP.ServerRuntime.Publisher do
  @moduledoc false
  # Last child of a server runtime: publishes the runtime snapshot once every
  # sibling runs, and is the first to stop, so lookups fail before shutdown.

  use GenServer

  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime

  def start_link(server_name), do: GenServer.start_link(__MODULE__, server_name)

  @impl true
  def init(server_name) do
    :ok = Registry.publish_runtime(server_name, ServerRuntime.snapshot(server_name))
    {:ok, server_name}
  end
end
