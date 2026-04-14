defmodule FastestMCP.CallSupervisor do
  @moduledoc """
  Supervises isolated call workers so handler crashes and timeouts stay contained.

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
    DynamicSupervisor.start_link(__MODULE__, opts, supervisor_options(opts))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: Keyword.get(opts, :max_children, :infinity)
    )
  end

  @doc "Invokes the compiled handler."
  def invoke(fun, timeout \\ nil) when is_function(fun, 0), do: invoke(__MODULE__, fun, timeout)

  def invoke(supervisor, fun, timeout)
      when (is_pid(supervisor) or is_atom(supervisor)) and is_function(fun, 0) do
    ref = make_ref()

    spec = {FastestMCP.CallWorker, %{ref: ref, reply_to: self(), fun: fun}}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        await_result(ref, pid, monitor, timeout)

      {:error, :max_children} ->
        {:error, :overloaded}

      {:error, {:max_children, _info}} ->
        {:error, :overloaded}

      other ->
        other
    end
  end

  defp await_result(ref, pid, monitor, timeout) do
    receive do
      {^ref, {:ok, value}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, value}

      {^ref, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:crash, reason}}
    after
      timeout || :infinity ->
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp supervisor_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
