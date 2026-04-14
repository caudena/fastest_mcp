defmodule FastestMCP.TaskElicitationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Elicitation.Cancelled
  alias FastestMCP.Elicitation.Declined
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "background tasks can elicit input and resume through the local API" do
    server_name = "task-elicit-local-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _args, ctx ->
          case Context.elicit(ctx, "What is your name?", :string) do
            %Accepted{data: name} -> "Hello, #{name}!"
            %Declined{} -> "User declined"
            %Cancelled{} -> "Cancelled"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    :ok = FastestMCP.EventBus.subscribe(runtime.event_bus, server_name)

    handle = FastestMCP.call_tool(server_name, "ask_name", %{}, task: true)
    notification = wait_for_input_required_notification(server_name, handle.task_id)

    assert notification.notification.params.taskId == handle.task_id
    assert notification.notification.params.status == "input_required"
    assert notification.notification.params.statusMessage == "What is your name?"
    assert notification.related_task.taskId == handle.task_id
    assert notification.related_task.status == "input_required"

    assert %{
             requestId: request_id,
             message: "What is your name?",
             requestedSchema: %{"type" => "string"}
           } = notification.related_task.elicitation

    task = FastestMCP.fetch_task(handle)
    assert task.status == :input_required
    assert task.elicitation.request_id == request_id

    updated =
      FastestMCP.send_task_input(server_name, handle.task_id, :accept, %{"value" => "Alice"})

    assert updated.status == :working
    assert FastestMCP.await_task(handle, 1_000) == "Hello, Alice!"
  end

  test "tasks/sendInput works through the shared task protocol and enforces session scope" do
    server_name = "task-elicit-protocol-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _args, ctx ->
          case Context.elicit(ctx, "Name?", :string) do
            %Accepted{data: name} -> "Hello, #{name}!"
            %Declined{} -> "Declined"
            %Cancelled{} -> "Cancelled"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "elicitation-session",
        task_request: true,
        payload: %{"name" => "ask_name", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    :ok = wait_for_input_required(server_name, task_id)

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "elicitation-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert status.status == "input_required"
    assert status.statusMessage == "Name?"
    assert status.taskId == task_id

    wrong_session_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/sendInput",
          transport: :stdio,
          session_id: "other-session",
          payload: %{
            "taskId" => task_id,
            "action" => "accept",
            "content" => %{"value" => "Mallory"}
          },
          request_metadata: %{session_id_provided: true}
        })
      end

    assert wrong_session_error.code == :invalid_task_id

    send_input =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/sendInput",
        transport: :stdio,
        session_id: "elicitation-session",
        payload: %{
          "taskId" => task_id,
          "action" => "accept",
          "content" => %{"value" => "Bob"}
        },
        request_metadata: %{session_id_provided: true}
      })

    assert send_input.taskId == task_id
    assert send_input.status == "working"

    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "elicitation-session") ==
             "Hello, Bob!"
  end

  test "send_task_input rejects non-waiting tasks and supports decline/cancel outcomes" do
    server_name = "task-elicit-outcomes-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "choose",
        fn %{"mode" => mode}, ctx ->
          case Context.elicit(ctx, "Provide input?", :string) do
            %Accepted{data: value} -> "#{mode}:#{value}"
            %Declined{} -> "#{mode}:declined"
            %Cancelled{} -> "#{mode}:cancelled"
          end
        end,
        task: true
      )
      |> FastestMCP.add_tool("done", fn _args, _ctx -> :ok end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    declined = FastestMCP.call_tool(server_name, "choose", %{"mode" => "first"}, task: true)
    :ok = wait_for_input_required(server_name, declined.task_id)
    _ = FastestMCP.send_task_input(server_name, declined.task_id, :decline, nil)
    assert FastestMCP.await_task(declined, 1_000) == "first:declined"

    cancelled = FastestMCP.call_tool(server_name, "choose", %{"mode" => "second"}, task: true)
    :ok = wait_for_input_required(server_name, cancelled.task_id)
    _ = FastestMCP.send_task_input(server_name, cancelled.task_id, :cancel, nil)
    assert FastestMCP.await_task(cancelled, 1_000) == "second:cancelled"

    completed = FastestMCP.call_tool(server_name, "done", %{}, task: true)
    assert FastestMCP.await_task(completed, 1_000) == :ok

    error =
      assert_raise Error, fn ->
        FastestMCP.send_task_input(server_name, completed.task_id, :accept, %{"value" => "late"})
      end

    assert error.code == :bad_request
  end

  defp wait_for_input_required(server_name, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_input_required(server_name, task_id, deadline)
  end

  defp wait_for_input_required_notification(server_name, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_input_required_notification(server_name, task_id, deadline)
  end

  defp do_wait_for_input_required(server_name, task_id, deadline) do
    task = FastestMCP.fetch_task(server_name, task_id)

    cond do
      task.status == :input_required ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for task #{inspect(task_id)} to reach input_required")

      true ->
        Process.sleep(10)
        do_wait_for_input_required(server_name, task_id, deadline)
    end
  end

  defp do_wait_for_input_required_notification(server_name, task_id, deadline) do
    receive do
      {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, event} ->
        related_task = event.related_task

        cond do
          related_task.taskId == task_id and event.notification.params.status == "input_required" ->
            event

          System.monotonic_time(:millisecond) >= deadline ->
            flunk(
              "timed out waiting for input_required notification for task #{inspect(task_id)}"
            )

          true ->
            do_wait_for_input_required_notification(server_name, task_id, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("timed out waiting for input_required notification for task #{inspect(task_id)}")
    end
  end
end
