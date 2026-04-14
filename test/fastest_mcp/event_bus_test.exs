defmodule FastestMCP.EventBusTest do
  use ExUnit.Case, async: false

  alias FastestMCP.EventBus

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  test "server-scoped subscribers keep receiving events across multiple emits" do
    {:ok, bus} = EventBus.start_link()
    assert :ok = EventBus.subscribe(bus, "server-a")

    EventBus.emit(bus, "server-a", [:one], %{count: 1}, %{server_name: "server-a"})
    EventBus.emit(bus, "server-a", [:two], %{count: 2}, %{server_name: "server-a"})

    assert_receive {:fastest_mcp_event, "server-a", [:one], %{count: 1},
                    %{server_name: "server-a"}}

    assert_receive {:fastest_mcp_event, "server-a", [:two], %{count: 2},
                    %{server_name: "server-a"}}

    state = :sys.get_state(bus)
    subscribers = Map.fetch!(state.servers, "server-a")
    assert Map.has_key?(subscribers, self())
  end

  test "subscriber cap rejects excess server subscribers and emits telemetry" do
    handler_id = "event-bus-cap-" <> Integer.to_string(System.unique_integer([:positive]))

    :telemetry.attach(
      handler_id,
      [:fastest_mcp, :event, :subscriber_rejected],
      &__MODULE__.handle_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, bus} = EventBus.start_link(max_server_subscribers: 1)
    assert :ok = EventBus.subscribe(bus, "server-a")

    caller = self()

    spawn(fn ->
      send(caller, {:subscribe_reply, EventBus.subscribe(bus, "server-a")})
    end)

    assert_receive {:subscribe_reply, {:error, :overloaded}}, 1_000

    assert_receive {:telemetry, [:fastest_mcp, :event, :subscriber_rejected], %{limit: 1},
                    %{scope: "server-a", reason: :subscriber_limit}},
                   1_000
  end

  test "backlogged subscribers are dropped from fanout and emit telemetry" do
    handler_id = "event-bus-drop-" <> Integer.to_string(System.unique_integer([:positive]))

    :telemetry.attach(
      handler_id,
      [:fastest_mcp, :event, :drop],
      &__MODULE__.handle_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, bus} = EventBus.start_link(max_subscriber_queue_len: 0)
    assert :ok = EventBus.subscribe(bus, "server-a")

    EventBus.emit(bus, "server-a", [:notifications, :tasks, :status], %{}, %{task_id: "task-1"})

    refute_receive {:fastest_mcp_event, "server-a", [:notifications, :tasks, :status], _, _}, 150

    assert_receive {:telemetry, [:fastest_mcp, :event, :drop],
                    %{dropped_subscribers: 1, sent_subscribers: 0, max_queue_len: 0},
                    %{
                      server_name: "server-a",
                      event_suffix: [:notifications, :tasks, :status],
                      reason: :subscriber_backlog
                    }},
                   1_000
  end
end
