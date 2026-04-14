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
    send(self(), :run)
    {:ok, opts}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info(:run, %{ref: ref, reply_to: reply_to, fun: fun} = state) do
    send(reply_to, {ref, run_fun(fun)})
    {:stop, :normal, state}
  end

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
