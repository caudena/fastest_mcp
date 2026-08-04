defmodule FastestMCP.PeerTaskTest do
  use ExUnit.Case, async: true

  alias FastestMCP.PeerTask

  test "builds a session-scoped peer task handle" do
    assert %PeerTask{
             server_name: "server",
             session_id: "session",
             task_id: "task",
             kind: :sampling,
             target: "sampling/createMessage"
           } =
             PeerTask.new(%{
               "server_name" => "server",
               "session_id" => "session",
               "task_id" => "task",
               kind: :sampling,
               target: "sampling/createMessage"
             })
  end

  test "rejects handles without exact session ownership" do
    assert_raise ArgumentError, ~r/session_id must be a non-empty string/, fn ->
      PeerTask.new(server_name: "server", session_id: nil, task_id: "task")
    end

    assert_raise ArgumentError, ~r/peer task kind/, fn ->
      PeerTask.new(server_name: "server", session_id: "session", task_id: "task", kind: :tool)
    end
  end
end
