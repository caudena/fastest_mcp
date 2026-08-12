defmodule FastestMCP.RuntimeAggregateQuotaTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Registry
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SSEReplay
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "bounds callbacks, active requests, and replay across every runtime session" do
    server_name = "runtime-quota-#{System.unique_integer([:positive])}"
    payload = %{"payload" => String.duplicate("x", 220)}
    replay_limit = replay_limit_for_two_cursors_and_one_notification(payload)

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name),
               max_runtime_pending_requests: 1,
               max_runtime_active_requests: 1,
               sse_replay_max_total_bytes: replay_limit
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    {session_a, sink_a} = initialized_session_with_sink!(server_name, "session-a")
    {session_b, sink_b} = initialized_session_with_sink!(server_name, "session-b")

    first_callback =
      Task.async(fn ->
        Session.request_peer(server_name, session_a, "roots/list", %{}, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_a, _event_id,
                    %{"id" => first_id, "method" => "roots/list"}}

    assert {:error, :overloaded} =
             Session.request_peer(server_name, session_b, "roots/list", %{})

    assert :ok =
             Session.resolve_peer_response(server_name, session_a, first_id, %{
               "jsonrpc" => "2.0",
               "id" => first_id,
               "result" => %{"roots" => []}
             })

    assert {:ok, %{"roots" => []}} = Task.await(first_callback)

    second_callback =
      Task.async(fn ->
        Session.request_peer(server_name, session_b, "roots/list", %{}, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_b, _event_id,
                    %{"id" => second_id, "method" => "roots/list"}}

    assert :ok =
             Session.resolve_peer_response(server_name, session_b, second_id, %{
               "jsonrpc" => "2.0",
               "id" => second_id,
               "result" => %{"roots" => []}
             })

    assert {:ok, %{"roots" => []}} = Task.await(second_callback)

    worker_a = spawn(fn -> Process.sleep(:infinity) end)
    worker_b = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = Session.register_inbound_request(server_name, session_a, 10, worker_a)

    assert {:error, :overloaded} =
             Session.register_inbound_request(server_name, session_b, 11, worker_b)

    assert :deliver = Session.finish_inbound_request(server_name, session_a, 10)
    assert :ok = Session.register_inbound_request(server_name, session_b, 11, worker_b)
    assert :deliver = Session.finish_inbound_request(server_name, session_b, 11)
    Process.exit(worker_a, :kill)
    Process.exit(worker_b, :kill)

    assert {:ok, %{event_id: event_a}} =
             Session.send_notification(server_name, session_a, "example/replay-a", payload)

    assert_receive {:fastest_mcp_session_message, ^sink_a, ^event_a,
                    %{"method" => "example/replay-a"}}

    assert {:error, :sse_replay_unavailable} =
             Session.send_notification(server_name, session_b, "example/replay-b", payload)

    refute_receive {:fastest_mcp_session_message, ^sink_b, _event_id,
                    %{"method" => "example/replay-b"}}

    {:ok, runtime} = ServerRuntime.fetch(server_name)
    snapshot = RuntimeQuota.snapshot(runtime.runtime_quota)
    {:ok, session_a_pid} = Registry.lookup_session(server_name, session_a)
    {:ok, session_b_pid} = Registry.lookup_session(server_name, session_b)
    replay_a = :sys.get_state(session_a_pid).replay.total_bytes
    replay_b = :sys.get_state(session_b_pid).replay.total_bytes

    assert snapshot.usage.pending_requests == 0
    assert snapshot.usage.active_requests == 0
    assert snapshot.usage.sse_replay_bytes == replay_a + replay_b
    assert snapshot.usage.sse_replay_bytes == replay_limit
    assert replay_a > replay_b
    assert replay_b > 0
  end

  defp replay_limit_for_two_cursors_and_one_notification(payload) do
    replay = SSEReplay.new(max_total_bytes: 1_000_000)
    {replay, stream_id, _replayed, :fresh} = SSEReplay.open(replay)
    {cursor_replay, _event_id, true} = SSEReplay.record_cursor(replay, stream_id)

    envelope = %{
      "jsonrpc" => "2.0",
      "method" => "example/replay-a",
      "params" => payload
    }

    {event_replay, _event_id, true} = SSEReplay.record(cursor_replay, stream_id, envelope)
    message_bytes = event_replay.total_bytes - cursor_replay.total_bytes

    2 * cursor_replay.total_bytes + message_bytes
  end

  defp initialized_session_with_sink!(server_name, session_id) do
    ProtocolTest.initialize_session(server_name, session_id, %{
      "capabilities" => %{"roots" => %{"listChanged" => true}}
    })

    assert {:ok, %{sink_ref: sink_ref}} =
             Session.attach_sink(server_name, session_id, self(), kind: :get)

    {session_id, sink_ref}
  end
end
