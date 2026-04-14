defmodule FastestMCP.TaskNotificationSubscriberTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "session subscribers receive only their session notifications and clean up with their owner" do
    parent = self()
    server_name = "task-subscriber-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _args, ctx ->
          send(parent, {:entered_task, ctx.session_id, self()})

          receive do
            :release -> :done
          after
            5_000 -> :timed_out
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert FastestMCP.task_notification_subscriber_count(server_name) == 0

    owner =
      spawn(fn ->
        {:ok, _pid} =
          FastestMCP.subscribe_task_notifications(server_name, "subscribed-session",
            owner: self(),
            target: parent
          )

        send(parent, :subscriber_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscriber_ready, 1_000
    wait_for_subscriber_count(server_name, 1)

    other =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "other-session",
        task_request: true,
        payload: %{"name" => "wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    assert_receive {:entered_task, "other-session", other_pid}, 1_000
    refute_receive {:fastest_mcp_task_notification, ^server_name, _notification}, 150

    subscribed =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "subscribed-session",
        task_request: true,
        payload: %{"name" => "wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    assert_receive {:entered_task, "subscribed-session", subscribed_pid}, 1_000

    assert_receive {:fastest_mcp_task_notification, ^server_name, notification}, 1_000
    assert notification.params.taskId == subscribed.task.taskId
    assert notification.params.status == "working"

    send(other_pid, :release)
    send(subscribed_pid, :release)

    assert FastestMCP.await_task(server_name, other.task.taskId, 1_000,
             session_id: "other-session"
           ) ==
             :done

    assert FastestMCP.await_task(server_name, subscribed.task.taskId, 1_000,
             session_id: "subscribed-session"
           ) == :done

    assert_receive {:fastest_mcp_task_notification, ^server_name, completed_notification}, 1_000
    assert completed_notification.params.taskId == subscribed.task.taskId
    assert completed_notification.params.status == "completed"

    send(owner, :stop)
    wait_for_subscriber_count(server_name, 0)
  end

  test "subscribers can automatically resolve input_required task notifications" do
    parent = self()

    server_name =
      "task-subscriber-elicitation-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _args, ctx ->
          case Context.elicit(ctx, "What is your name?", :string) do
            %FastestMCP.Elicitation.Accepted{data: name} -> "Hello, #{name}!"
            %FastestMCP.Elicitation.Declined{} -> "Declined"
            %FastestMCP.Elicitation.Cancelled{} -> "Cancelled"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert {:ok, subscriber} =
             FastestMCP.subscribe_task_notifications(server_name, "relay-session",
               target: self(),
               elicitation_handler: fn notification ->
                 send(parent, {:elicitation_seen, notification})
                 {:accept, %{"value" => "Alice"}}
               end
             )

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "relay-session",
        task_request: true,
        payload: %{"name" => "ask_name", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    assert_receive {:fastest_mcp_task_notification, ^server_name, notification}, 1_000
    assert notification.params.taskId == task_id
    assert notification.params.status == "working"

    assert_receive {:elicitation_seen, elicitation_notification}, 1_000
    assert elicitation_notification.task_id == task_id
    assert elicitation_notification.notification.params.taskId == task_id
    assert elicitation_notification.notification.params.status == "input_required"
    assert elicitation_notification.related_task.status == "input_required"

    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "relay-session") ==
             "Hello, Alice!"

    GenServer.stop(subscriber)
  end

  test "task notification subscriptions are rejected when event fanout is at capacity" do
    server_name =
      "task-subscriber-cap-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("noop", fn _args, _ctx -> :ok end)

    assert {:ok, _pid} =
             FastestMCP.start_server(server, max_event_subscribers_per_server: 1)

    assert {:ok, first} =
             FastestMCP.subscribe_task_notifications(server_name, "session-a", owner: self())

    assert {:error, :overloaded} =
             FastestMCP.subscribe_task_notifications(server_name, "session-b", owner: self())

    GenServer.stop(first)
  end

  defp wait_for_subscriber_count(server_name, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_subscriber_count(server_name, expected, deadline)
  end

  defp do_wait_for_subscriber_count(server_name, expected, deadline) do
    if FastestMCP.task_notification_subscriber_count(server_name) == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for subscriber count #{inspect(expected)}")
      else
        Process.sleep(10)
        do_wait_for_subscriber_count(server_name, expected, deadline)
      end
    end
  end
end
