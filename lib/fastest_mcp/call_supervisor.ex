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
      {^ref, result} ->
        finish_result(ref, monitor, result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        case take_result(ref) do
          {:ok, result} -> finish_result(ref, monitor, result)
          :error -> {:error, {:crash, reason}}
        end
    after
      timeout || :infinity ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        flush_results(ref)
        {:error, :timeout}
    end
  end

  defp finish_result(ref, monitor, result) do
    Process.demonitor(monitor, [:flush])
    flush_results(ref)
    result
  end

  defp take_result(ref) do
    receive do
      {^ref, result} -> {:ok, result}
    after
      0 -> :error
    end
  end

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp flush_results(ref) do
    receive do
      {^ref, _result} -> flush_results(ref)
    after
      0 -> :ok
    end
  end

  defp supervisor_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
