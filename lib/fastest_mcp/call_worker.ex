defmodule FastestMCP.CallWorker do
  @moduledoc """
  Runs one delegated function call inside an isolated worker process.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use GenServer

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:ref] || make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Starts the process owned by this module."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    caller_monitor = Process.monitor(Map.fetch!(opts, :reply_to))
    send(self(), :run)
    {:ok, Map.merge(opts, %{caller_monitor: caller_monitor, runner: nil})}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info(:run, %{ref: ref, fun: fun} = state) do
    owner = self()
    runner = spawn_link(fn -> send(owner, {ref, run_fun(fun)}) end)
    {:noreply, %{state | runner: runner}}
  end

  def handle_info(
        {ref, result},
        %{ref: ref, reply_to: reply_to, caller_monitor: caller_monitor} = state
      ) do
    Process.demonitor(caller_monitor, [:flush])
    send(reply_to, {ref, result})
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, caller_monitor, :process, reply_to, _reason},
        %{caller_monitor: caller_monitor, reply_to: reply_to} = state
      ) do
    stop_runner(state.runner)
    {:stop, :normal, %{state | runner: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    stop_runner(Map.get(state, :runner))
    :ok
  end

  defp stop_runner(runner) when is_pid(runner) do
    if Process.alive?(runner), do: Process.exit(runner, :kill)
    :ok
  end

  defp stop_runner(_runner), do: :ok

  defp run_fun(fun) do
    try do
      {:ok, fun.()}
    rescue
      error ->
        {:error, {:exception, error, __STACKTRACE__}}
    catch
      :exit, reason ->
        {:error, {:exit, reason}}

      kind, reason ->
        {:error, {kind, reason}}
    end
  end
end
