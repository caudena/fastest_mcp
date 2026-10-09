defmodule FastestMCP.ServerRuntime.Calls do
  @moduledoc false
  # The one exception boundary around handler code. Each call is a task under
  # the runtime's `:calls` Task.Supervisor, whose `:max_children` bounds
  # concurrent calls. The task turns every raise, throw, and exit into a
  # tagged result. It is not linked to the caller, so a crashing process the
  # handler linked to cannot take the caller down; a watcher kills the task
  # if the caller dies first.

  @type reason :: :overloaded | :timeout | {:error | :exit | :throw | :crash, term()}

  @spec run(Supervisor.supervisor(), (-> term()), timeout() | nil) ::
          {:ok, term()} | {:error, reason()}
  def run(supervisor, fun, timeout) when is_function(fun, 0) do
    with {:ok, task} <- start(supervisor, self(), fun) do
      case Task.yield(task, timeout || :infinity) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:crash, reason}}
        nil -> {:error, :timeout}
      end
    end
  end

  defp start(supervisor, caller, fun) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fn -> run_task(caller, fun) end)}
  rescue
    # Task.Supervisor raises once it already runs :max_children tasks.
    RuntimeError -> {:error, :overloaded}
  end

  defp run_task(caller, fun) do
    watch(caller, self())
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {kind, Exception.normalize(kind, reason, __STACKTRACE__)}}
  end

  defp watch(caller, task) do
    spawn(fn ->
      caller_ref = Process.monitor(caller)
      task_ref = Process.monitor(task)

      receive do
        {:DOWN, ^caller_ref, _, _, _} -> Process.exit(task, :kill)
        {:DOWN, ^task_ref, _, _, _} -> :ok
      end
    end)
  end
end
