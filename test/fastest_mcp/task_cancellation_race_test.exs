defmodule FastestMCP.TaskCancellationRaceTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "a late worker result cannot overwrite cancellation" do
    server_name = "task-cancel-race-#{System.unique_integer([:positive])}"
    session_id = "task-cancel-race-session"

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "wait",
      fn _arguments, _context ->
        receive do
          :never -> :unreachable
        end
      end,
      task: true
    )
    |> start_server!()

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: session_id,
        task_request: true,
        payload: %{"name" => "wait", "arguments" => %{}},
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    task_store = runtime.task_store

    :ok = :sys.suspend(task_store)

    try do
      cancel =
        Task.async(fn ->
          FastestMCP.cancel_task!(server_name, task_id, session_id: session_id)
        end)

      assert_eventually(fn -> cancel_queued?(task_store, task_id) end)

      send(task_store, {:task_result, task_id, {:ok, :late_result}})
      :ok = :sys.resume(task_store)

      assert %{status: :cancelled} = Task.await(cancel, 1_000)

      assert %{status: :cancelled} =
               FastestMCP.fetch_task!(server_name, task_id, session_id: session_id)
    after
      resume_if_suspended(task_store)
    end
  end

  defp cancel_queued?(task_store, task_id) do
    task_store
    |> Process.info(:messages)
    |> elem(1)
    |> Enum.any?(fn
      {:"$gen_call", _from, {:cancel, ^task_id, _opts}} -> true
      _message -> false
    end)
  end

  defp resume_if_suspended(task_store) do
    :sys.resume(task_store)
  catch
    :exit, _reason -> :ok
  end
end
