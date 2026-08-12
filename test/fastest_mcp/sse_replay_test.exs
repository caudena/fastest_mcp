defmodule FastestMCP.SSEReplayTest do
  use ExUnit.Case, async: true

  alias FastestMCP.SSEReplay

  test "replays only events after an id from the same stream" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 10_000, max_total_bytes: 20_000)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, first_id, true} = SSEReplay.record(replay, stream_id, %{"n" => 1}, now_ms: 2)
    {replay, second_id, true} = SSEReplay.record(replay, stream_id, %{"n" => 2}, now_ms: 3)

    assert {_, ^stream_id, [%{id: ^second_id}], :resumed} =
             SSEReplay.open(replay, first_id, 4)
  end

  test "replays the retained tail again when a reconnect repeats the same cursor" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 10_000, max_total_bytes: 20_000)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, first_id, true} = SSEReplay.record(replay, stream_id, %{"n" => 1}, now_ms: 2)
    {replay, second_id, true} = SSEReplay.record(replay, stream_id, %{"n" => 2}, now_ms: 3)

    assert {replay, ^stream_id, [%{id: ^second_id}], :resumed} =
             SSEReplay.open(replay, first_id, 4)

    assert {_replay, ^stream_id, [%{id: ^second_id}], :resumed} =
             SSEReplay.open(replay, first_id, 5)
  end

  test "never crosses logical stream boundaries" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 10_000, max_total_bytes: 20_000)
    {replay, first_stream, [], :fresh} = SSEReplay.open(replay, nil, 1)

    {replay, first_id, true} =
      SSEReplay.record(replay, first_stream, %{"stream" => "first", "n" => 1}, now_ms: 2)

    {replay, second_stream, [], :fresh} = SSEReplay.open(replay, nil, 3)

    {replay, _second_id, true} =
      SSEReplay.record(replay, second_stream, %{"stream" => "second", "n" => 1}, now_ms: 4)

    {replay, first_second_id, true} =
      SSEReplay.record(replay, first_stream, %{"stream" => "first", "n" => 2}, now_ms: 5)

    assert {_, ^first_stream, [%{id: ^first_second_id, envelope: envelope}], :resumed} =
             SSEReplay.open(replay, first_id, 6)

    assert envelope == %{"stream" => "first", "n" => 2}
  end

  test "malformed ids are rejected without creating a logical stream" do
    replay = SSEReplay.new()
    {replay, first_stream, [], :fresh} = SSEReplay.open(replay, nil, 1)

    assert {malformed_replay, nil, [], {:error, :malformed}} =
             SSEReplay.open(replay, "bad-id", 2)

    assert malformed_replay.streams == replay.streams

    assert {colon_replay, nil, [], {:error, :malformed}} =
             SSEReplay.open(replay, "unknown:1", 2)

    assert colon_replay.streams == replay.streams
    refute Map.has_key?(replay.streams, first_stream)
  end

  test "retains cursor events as resumable, quota-accounted stream positions" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 10_000, max_total_bytes: 20_000)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, cursor_id, true} = SSEReplay.record_cursor(replay, stream_id, now_ms: 2)

    assert replay.total_bytes > 0
    assert {replay, ^stream_id, [], :resumed} = SSEReplay.open(replay, cursor_id, 3)

    {replay, message_id, true} =
      SSEReplay.record(replay, stream_id, %{"after" => "cursor"}, now_ms: 4)

    assert {_, ^stream_id, [%{id: ^message_id, kind: :message, envelope: %{"after" => "cursor"}}],
            :resumed} = SSEReplay.open(replay, cursor_id, 5)
  end

  test "does not retain or leak an empty stream when a cursor exceeds its quota" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 1, max_total_bytes: 1)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)

    assert {replay, cursor_id, false} =
             SSEReplay.record_cursor(replay, stream_id, now_ms: 2)

    assert replay.total_bytes == 0
    assert replay.streams == %{}
    assert {_, nil, [], {:error, :expired}} = SSEReplay.open(replay, cursor_id, 3)
  end

  test "distinguishes a foreign session id from an already-pruned current-session id" do
    replay = SSEReplay.new(ttl_ms: 10)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, event_id, true} = SSEReplay.record(replay, stream_id, %{"id" => 1}, now_ms: 2)

    # Prune in a separate operation first, so classification cannot rely on a
    # transient copy of the stream that existed at the start of `open/3`.
    replay = SSEReplay.prune(replay, 20)
    refute Map.has_key?(replay.streams, stream_id)
    assert {_, nil, [], {:error, :expired}} = SSEReplay.open(replay, event_id, 21)

    {replay, recreated_id, true} =
      SSEReplay.record(replay, stream_id, %{"id" => 2}, now_ms: 22)

    refute recreated_id == event_id
    assert {_, nil, [], {:error, :expired}} = SSEReplay.open(replay, event_id, 23)

    foreign = SSEReplay.new()
    {foreign, foreign_stream, [], :fresh} = SSEReplay.open(foreign, nil, 1)

    {_, foreign_event_id, true} =
      SSEReplay.record(foreign, foreign_stream, %{"id" => 1}, now_ms: 2)

    assert {_, nil, [], {:error, :unknown}} = SSEReplay.open(replay, foreign_event_id, 22)
  end

  test "bounds retention and acknowledgement without dropping the delivered event id" do
    replay = SSEReplay.new(max_events: 3, max_stream_bytes: 300, max_total_bytes: 300)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)

    {replay, first, true} =
      SSEReplay.record(replay, stream_id, %{"id" => 1}, request_id: "one", now_ms: 2)

    {replay, second, true} =
      SSEReplay.record(replay, stream_id, %{"id" => 2}, request_id: "two", now_ms: 3)

    {replay, third, true} =
      SSEReplay.record(replay, stream_id, %{"id" => 3}, request_id: "three", now_ms: 4)

    assert {_, ^stream_id, [%{id: ^second}, %{id: ^third}], :resumed} =
             SSEReplay.open(replay, first, 5)

    replay = SSEReplay.acknowledge(replay, "two")

    assert {_, ^stream_id, [%{id: ^third}], :resumed} = SSEReplay.open(replay, first, 6)

    assert {_, nil, [], {:error, :expired}} = SSEReplay.open(replay, second, 6)
  end

  test "expired streams cannot be resumed" do
    replay = SSEReplay.new(ttl_ms: 10)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, event_id, true} = SSEReplay.record(replay, stream_id, %{"id" => 1}, now_ms: 2)

    assert {_, nil, [], {:error, :expired}} = SSEReplay.open(replay, event_id, 20)
  end

  test "evicted event ids cannot resume a partial stream" do
    replay = SSEReplay.new(max_events: 2, max_stream_bytes: 10_000, max_total_bytes: 20_000)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, first_id, true} = SSEReplay.record(replay, stream_id, %{"id" => 1}, now_ms: 2)
    {replay, _second_id, true} = SSEReplay.record(replay, stream_id, %{"id" => 2}, now_ms: 3)
    {replay, _third_id, true} = SSEReplay.record(replay, stream_id, %{"id" => 3}, now_ms: 4)

    assert {_, nil, [], {:error, :expired}} =
             SSEReplay.open(replay, first_id, 5)
  end

  test "reports an event as unretained when the total-byte bound evicts it immediately" do
    replay = SSEReplay.new(max_events: 4, max_stream_bytes: 1_000, max_total_bytes: 10)
    {replay, stream_id, [], :fresh} = SSEReplay.open(replay, nil, 1)
    {replay, retained_id, true} = SSEReplay.record(replay, stream_id, "a", now_ms: 2)
    retained_bytes = replay.total_bytes

    assert {replay, event_id, false} =
             SSEReplay.record(replay, stream_id, %{"payload" => "larger than ten bytes"},
               now_ms: 3
             )

    assert replay.total_bytes == retained_bytes
    assert {_, ^stream_id, [], :resumed} = SSEReplay.open(replay, retained_id, 4)

    assert {_, nil, [], {:error, :expired}} =
             SSEReplay.open(replay, event_id, 4)
  end
end
