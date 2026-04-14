defmodule FastestMCP.ServerSupervisor do
  @moduledoc """
  Dynamic supervisor used to run server runtimes started through the facade API.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use DynamicSupervisor

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts a server runtime."
  def start_server(server, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {FastestMCP.ServerRuntime, {server, opts}})
  end

  @doc "Stops a running server runtime."
  def stop_server(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
