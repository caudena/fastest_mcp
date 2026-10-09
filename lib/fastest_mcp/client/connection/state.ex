defmodule FastestMCP.Client.Connection.State do
  @moduledoc false
  # Process state of `FastestMCP.Client.Connection`. `config` holds the
  # validated options; its handlers, roots and auth input change at runtime.
  # Each core owns one sub-struct, and `monitors` maps every monitor reference
  # to the tag whose `:DOWN` the connection handles.

  alias FastestMCP.Client.Connection.CallbackTasks
  alias FastestMCP.Client.Connection.Catalog
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.Stdio
  alias FastestMCP.Client.ToolCatalog

  # The sub-structs are built in `new/1`: as field defaults they would be
  # built at compile time, a compile-time dependency on every core.
  @enforce_keys [:config, :transport, :lifecycle, :outbound, :callbacks, :stdio, :catalog]
  defstruct [
    :config,
    :transport,
    :worker_supervisor,
    :dispatcher,
    :oauth,
    :session_stream,
    :recovery,
    :lifecycle,
    :outbound,
    :callbacks,
    :stdio,
    :catalog,
    tasks: %{},
    monitors: %{}
  ]

  @type t :: %__MODULE__{}

  def new(config) do
    %__MODULE__{
      config: config,
      transport: config.transport,
      lifecycle: %Lifecycle{},
      outbound: %Outbound{},
      callbacks: %CallbackTasks{},
      stdio: %Stdio{},
      catalog: %Catalog{tools: %ToolCatalog{}, responses: config.response_cache}
    }
  end

  def monitor(state, pid, tag) do
    ref = Process.monitor(pid)
    {ref, %{state | monitors: Map.put(state.monitors, ref, tag)}}
  end

  def demonitor(state, nil), do: state

  def demonitor(state, ref) do
    Process.demonitor(ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, ref)}
  end
end
