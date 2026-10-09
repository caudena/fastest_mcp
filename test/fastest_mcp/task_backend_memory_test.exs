defmodule FastestMCP.TaskBackendMemoryTest do
  # Not async: the atom-count test reads a VM-wide counter that any
  # concurrently running test can move by loading a module.
  use FastestMCP.Case

  alias FastestMCP.BackgroundTaskStore.Task, as: TaskRecord
  alias FastestMCP.TaskBackend.Memory

  test "initializing the backend does not create fresh atoms" do
    {:ok, _warmup} = Memory.init([])
    before = :erlang.system_info(:atom_count)

    {:ok, _first} = Memory.init([])
    {:ok, _second} = Memory.init([])

    assert :erlang.system_info(:atom_count) == before
  end

  test "stores, replaces, lists, and deletes task records" do
    {:ok, table} = Memory.init([])
    first = %TaskRecord{id: "task-1", submitted_at: 1}

    {:ok, table} = Memory.put_task(table, first)
    {:ok, table} = Memory.put_task(table, %TaskRecord{id: "task-2", submitted_at: 2})
    {:ok, table} = Memory.put_task(table, %{first | status: :completed})

    assert {:ok, %TaskRecord{status: :completed}} = Memory.fetch_task(table, "task-1")
    assert {:ok, tasks} = Memory.list_tasks(table)
    assert tasks |> Enum.map(& &1.id) |> Enum.sort() == ["task-1", "task-2"]

    assert {:ok, table} = Memory.delete_task(table, "task-1")
    assert {:error, :not_found} = Memory.fetch_task(table, "task-1")
    assert {:ok, [%TaskRecord{id: "task-2"}]} = Memory.list_tasks(table)
  end
end
