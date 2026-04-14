defmodule FastestMCP.TaskBackendMemoryTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.TaskBackend.Memory

  setup do
    {:ok, backend} = start_supervised(Memory)
    %{backend: backend}
  end

  test "starting the backend does not create fresh atoms" do
    {:ok, warmup} = Memory.start_link([])
    GenServer.stop(warmup)

    before = :erlang.system_info(:atom_count)
    {:ok, first} = Memory.start_link([])
    {:ok, second} = Memory.start_link([])

    GenServer.stop(first)
    GenServer.stop(second)

    assert :erlang.system_info(:atom_count) == before
  end

  test "lists tasks with opaque cursor pagination globally and per session", %{backend: backend} do
    insert_task!(backend, id: "task-1", session_id: "session-a", submitted_at: 1_000)
    insert_task!(backend, id: "task-2", session_id: "session-b", submitted_at: 2_000)
    insert_task!(backend, id: "task-3", session_id: "session-a", submitted_at: 3_000)

    assert {:ok, %{tasks: first_page, next_cursor: global_cursor}} =
             Memory.list_tasks(backend, page_size: 2)

    assert Enum.map(first_page, & &1.id) == ["task-3", "task-2"]
    assert is_binary(global_cursor)

    assert {:ok, %{tasks: second_page, next_cursor: nil}} =
             Memory.list_tasks(backend, page_size: 2, cursor: global_cursor)

    assert Enum.map(second_page, & &1.id) == ["task-1"]

    assert {:ok, %{tasks: session_tasks, next_cursor: nil}} =
             Memory.list_tasks(backend, session_id: "session-a")

    assert Enum.map(session_tasks, & &1.id) == ["task-3", "task-1"]
  end

  test "rejects invalid or scope-mismatched cursors without crashing the backend", %{
    backend: backend
  } do
    insert_task!(backend, id: "task-1", session_id: "session-a", submitted_at: 1_000)
    insert_task!(backend, id: "task-2", session_id: "session-a", submitted_at: 2_000)

    assert {:error, %Error{code: :bad_request, message: "invalid cursor"}} =
             Memory.list_tasks(backend, session_id: "session-a", cursor: "invalid")

    assert {:ok, %{next_cursor: cursor}} =
             Memory.list_tasks(backend, session_id: "session-a", page_size: 1)

    assert is_binary(cursor)

    assert {:error, %Error{code: :bad_request, message: "invalid cursor"}} =
             Memory.list_tasks(backend, session_id: "session-b", cursor: cursor)

    assert {:ok, %{tasks: tasks, next_cursor: nil}} =
             Memory.list_tasks(backend, session_id: "session-a")

    assert Enum.map(tasks, & &1.id) == ["task-2", "task-1"]
  end

  test "expires tasks and removes them from fetch and listing indexes", %{backend: backend} do
    insert_task!(backend,
      id: "expired-task",
      session_id: "session-a",
      submitted_at: 1_000,
      expires_at: 1_500
    )

    insert_task!(backend,
      id: "fresh-task",
      session_id: "session-a",
      submitted_at: 2_000,
      expires_at: 4_000
    )

    assert ["expired-task"] == Memory.expire_tasks(backend, 2_000)
    assert :error == Memory.fetch_task(backend, "expired-task")
    assert {:ok, _task} = Memory.fetch_task(backend, "fresh-task", session_id: "session-a")

    assert {:ok, %{tasks: tasks, next_cursor: nil}} =
             Memory.list_tasks(backend, session_id: "session-a")

    assert Enum.map(tasks, & &1.id) == ["fresh-task"]
  end

  defp insert_task!(backend, attrs) do
    task = task(attrs)
    assert :ok == Memory.put_task(backend, task)
    task
  end

  defp task(attrs) do
    submitted_at = Keyword.fetch!(attrs, :submitted_at)
    id = Keyword.fetch!(attrs, :id)

    %{
      id: id,
      session_id: Keyword.get(attrs, :session_id, "session-a"),
      submitted_at: submitted_at,
      updated_at: submitted_at,
      expires_at: Keyword.get(attrs, :expires_at),
      ttl_ms: Keyword.get(attrs, :ttl_ms, 60_000),
      poll_interval_ms: Keyword.get(attrs, :poll_interval_ms, 500),
      status: Keyword.get(attrs, :status, :working)
    }
  end
end
