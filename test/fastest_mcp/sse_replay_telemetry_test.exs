defmodule FastestMCP.SSEReplayTelemetryTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "malformed and unknown resume ids are rejected and emit bounded telemetry" do
    attach_telemetry([[:fastest_mcp, :sse, :replay_reset]])
    server_name = "sse-replay-telemetry-#{System.unique_integer([:positive])}"
    session_id = "session"
    start_server!(FastestMCP.server(server_name))
    ProtocolTest.initialize_session(server_name, session_id)

    assert {:error, {:last_event_id, :malformed}} =
             Session.attach_sink(server_name, session_id, self(),
               kind: :get,
               last_event_id: "not-an-event-id"
             )

    assert_receive {:telemetry, [:fastest_mcp, :sse, :replay_reset], %{count: 1},
                    %{reason: :malformed, server_name: ^server_name, session_id: ^session_id}}

    foreign_session_id = "foreign-session"
    ProtocolTest.initialize_session(server_name, foreign_session_id)

    assert {:ok, %{sink_ref: foreign_sink_ref}} =
             Session.attach_sink(server_name, foreign_session_id, self(), kind: :get)

    assert_receive {:fastest_mcp_session_cursor, ^foreign_sink_ref, foreign_event_id}

    assert {:error, {:last_event_id, :unknown}} =
             Session.attach_sink(server_name, session_id, self(),
               kind: :get,
               last_event_id: foreign_event_id
             )

    assert_receive {:telemetry, [:fastest_mcp, :sse, :replay_reset], %{count: 1},
                    %{reason: :unknown, server_name: ^server_name, session_id: ^session_id}}
  end
end
