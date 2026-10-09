defmodule FastestMCP.TaskBackend.Memory do
  @moduledoc """
  The default task backend: an ETS table owned by the server's task store.

  Task records live as long as the server runtime. A host that needs tasks to
  survive restarts or span nodes provides a durable `FastestMCP.TaskBackend`.
  """

  @behaviour FastestMCP.TaskBackend

  @impl true
  def init(_opts), do: {:ok, :ets.new(__MODULE__, [:set, :private])}

  @impl true
  def put_task(table, task) do
    true = :ets.insert(table, {task.id, task})
    {:ok, table}
  end

  @impl true
  def fetch_task(table, task_id) do
    case :ets.lookup(table, task_id) do
      [{_task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete_task(table, task_id) do
    true = :ets.delete(table, task_id)
    {:ok, table}
  end

  @impl true
  def list_tasks(table), do: {:ok, :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])}
end
