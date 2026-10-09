defmodule FastestMCP.EventBusTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.EventBus

  test "server-scoped subscribers keep receiving events across multiple emits" do
    server_name = unique_name("events")
    other_server = unique_name("other-events")
    bus = %EventBus{}

    assert :ok = EventBus.subscribe(bus, server_name)
    assert :ok = EventBus.subscribe(bus, server_name)

    EventBus.emit(bus, server_name, [:one], %{count: 1}, %{server_name: server_name})
    EventBus.emit(bus, other_server, [:other], %{count: 3}, %{})
    EventBus.emit(bus, server_name, [:two], %{count: 2}, %{server_name: server_name})

    assert_receive {:fastest_mcp_event, ^server_name, [:one], %{count: 1},
                    %{server_name: ^server_name}}

    assert_receive {:fastest_mcp_event, ^server_name, [:two], %{count: 2},
                    %{server_name: ^server_name}}

    refute_receive {:fastest_mcp_event, _server_name, _event, _measurements, _metadata}, 50

    assert :ok = EventBus.unsubscribe(server_name)
    EventBus.emit(bus, server_name, [:three], %{count: 3}, %{})
    refute_receive {:fastest_mcp_event, ^server_name, [:three], _measurements, _metadata}, 50
  end

  test "subscriber cap rejects excess server subscribers and emits telemetry" do
    server_name = unique_name("capped-events")

    attach_telemetry([[:fastest_mcp, :event, :subscriber_rejected]])

    bus = %EventBus{max_subscribers: 1}
    assert :ok = EventBus.subscribe(bus, server_name)

    caller = self()

    spawn(fn ->
      send(caller, {:subscribe_reply, EventBus.subscribe(bus, server_name)})
    end)

    assert_receive {:subscribe_reply, {:error, :overloaded}}, 1_000

    assert_receive {:telemetry, [:fastest_mcp, :event, :subscriber_rejected], %{limit: 1},
                    %{scope: ^server_name, reason: :subscriber_limit}},
                   1_000
  end

  test "backlogged subscribers are dropped from fanout and emit telemetry" do
    server_name = unique_name("backlogged-events")

    attach_telemetry([[:fastest_mcp, :event, :drop]])

    bus = %EventBus{max_queue_len: 0}
    assert :ok = EventBus.subscribe(bus, server_name)

    EventBus.emit(bus, server_name, [:notifications, :tasks, :status], %{}, %{task_id: "task-1"})

    refute_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, _},
                   150

    assert_receive {:telemetry, [:fastest_mcp, :event, :drop],
                    %{dropped_subscribers: 1, sent_subscribers: 0, max_queue_len: 0},
                    %{
                      server_name: ^server_name,
                      event_suffix: [:notifications, :tasks, :status],
                      reason: :subscriber_backlog
                    }},
                   1_000
  end
end
