defmodule FastestMCP.SSEReplayTelemetryTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  test "malformed and unknown resume ids are rejected and emit bounded telemetry" do
    handler_id = "sse-replay-reset-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fastest_mcp, :sse, :replay_reset],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    server_name = "sse-replay-telemetry-#{System.unique_integer([:positive])}"
    session_id = "session"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
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
