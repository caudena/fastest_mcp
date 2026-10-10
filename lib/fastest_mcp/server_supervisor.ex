defmodule FastestMCP.ServerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_server(server, opts \\ []) do
    __MODULE__
    |> DynamicSupervisor.start_child({FastestMCP.ServerRuntime, {server, opts}})
    |> unwrap_start_error()
  end

  # A child that fails to start surfaces as nested supervisor errors; callers
  # get the child's own reason.
  def unwrap_start_error({:error, {:shutdown, {:failed_to_start_child, _child, reason}}}),
    do: unwrap_start_error({:error, reason})

  def unwrap_start_error(result), do: result

  def stop_server(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
