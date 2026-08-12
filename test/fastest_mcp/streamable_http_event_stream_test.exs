defmodule FastestMCP.StreamableHTTPEventStreamTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Registry
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "streamable HTTP uses event-stream framing for tool calls" do
    server_name = "http-event-stream-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name)
    session_id = initialize_session(port)

    response =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(7, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"message" => "hi"}
        }),
        session_id
      )

    assert response.status == 200
    assert Map.get(response.headers, "content-type") == "text/event-stream"
    assert Map.get(response.headers, "mcp-session-id") == session_id

    assert response.body =~
             ~r/\Aid: [A-Za-z0-9_-]+\nretry: 1000\ndata:\n\nid: [A-Za-z0-9_-]+\nevent: message\ndata: \{"id":7,"jsonrpc":"2.0"/

    assert response.body =~ "event: message\n"
    assert response.body =~ "\"jsonrpc\":\"2.0\""
    assert response.body =~ "\"structuredContent\":{\"message\":\"hi\"}"
  end

  test "a resumed GET exclusively receives an overlapping POST's live events" do
    parent = self()
    server_name = "http-overlap-owner-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("overlap", fn _arguments, context ->
        send(parent, {:overlap_started, self()})

        receive do
          :emit_overlap_notification ->
            delivery =
              Context.send_notification(
                context,
                "notifications/overlap-owner",
                %{"sequence" => 1}
              )

            send(parent, {:overlap_notification_sent, delivery})
        end

        receive do
          :finish_overlap -> %{"owner" => "resumed"}
        end
      end)

    assert {:ok, _pid} =
             FastestMCP.start_server(server, session_idle_ttl: :infinity)

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    payload =
      ProtocolTest.jsonrpc_request(77, "tools/call", %{
        "name" => "overlap",
        "arguments" => %{}
      })

    {:ok, post_socket, %{status: 200}, post_state} =
      open_post_stream(port, payload, session_id)

    try do
      assert_receive {:overlap_started, operation_pid}, 1_000

      assert {:ok, post_cursor_stream, post_state} =
               recv_stream_until(post_socket, post_state, "retry: 1000", 1_000)

      [first_cursor] =
        Regex.run(~r/^id: ([^\n]+)$/m, post_cursor_stream, capture: :all_but_first)

      {:ok, get_socket, %{status: 200}, get_state} =
        open_session_stream(port, session_id, first_cursor)

      try do
        assert {:ok, _get_cursor_stream, get_state} =
                 recv_stream_until(get_socket, get_state, "retry: 1000", 1_000)

        send(operation_pid, :emit_overlap_notification)

        assert_receive {:overlap_notification_sent,
                        {:ok,
                         %{
                           sink_ref: post_ref,
                           delivery_sink_ref: get_ref,
                           event_id: notification_id
                         }}},
                       1_000

        assert is_reference(post_ref)
        assert is_reference(get_ref)
        refute post_ref == get_ref

        assert {:ok, notification_stream, get_state} =
                 recv_stream_until(
                   get_socket,
                   get_state,
                   "notifications/overlap-owner",
                   1_000
                 )

        assert notification_stream =~ "id: #{notification_id}\n"

        assert length(
                 Regex.scan(
                   ~r/"method":"notifications\/overlap-owner"/,
                   notification_stream
                 )
               ) == 1

        assert {:error, :timeout} = :gen_tcp.recv(post_socket, 0, 100)

        send(operation_pid, :finish_overlap)

        assert {:ok, completed_stream, _get_state} =
                 recv_stream_until(get_socket, get_state, "\"owner\":\"resumed\"", 1_000)

        assert length(
                 Regex.scan(
                   ~r/"method":"notifications\/overlap-owner"/,
                   completed_stream
                 )
               ) == 1

        assert length(Regex.scan(~r/"id":77/, completed_stream)) == 1

        post_stream = recv_stream_tail(post_socket, post_state, 1_000)
        refute post_stream =~ "notifications/overlap-owner"
        refute post_stream =~ "\"owner\":\"resumed\""
        refute post_stream =~ "\"id\":77"
      after
        close_session_stream(get_socket, server_name, session_id, session_pid, 78)
      end
    after
      :gen_tcp.close(post_socket)
    end
  end

  test "GET session event streams relay task notifications for the same session" do
    parent = self()
    server_name = "http-session-stream-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _arguments, ctx ->
          send(parent, {:session_stream_task_started, ctx.session_id, self()})

          receive do
            :release -> %{done: true}
          after
            5_000 -> %{timed_out: true}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name, json_response: true)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    {:ok, socket, response, stream_state} = open_session_stream(port, session_id)

    try do
      assert response.status == 200
      assert Map.get(response.headers, "content-type") == "text/event-stream"
      assert Map.get(response.headers, "mcp-session-id") == session_id

      task_response =
        post_json(
          port,
          ProtocolTest.jsonrpc_request(9, "tools/call", %{
            "name" => "wait",
            "arguments" => %{},
            "task" => %{}
          }),
          session_id
        )

      assert task_response.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => 9,
               "result" => %{"task" => %{"taskId" => task_id, "status" => "working"}}
             } = JSON.decode!(task_response.body)

      assert_receive {:session_stream_task_started, ^session_id, task_pid}, 1_000

      assert {:ok, working_stream, stream_state} =
               recv_stream_until(socket, stream_state, "\"status\":\"working\"", 1_000)

      assert working_stream =~ "\"method\":\"notifications/tasks/status\""
      assert working_stream =~ "\"taskId\":\"#{task_id}\""

      send(task_pid, :release)

      assert {:ok, completed_stream, _stream_state} =
               recv_stream_until(socket, stream_state, "\"status\":\"completed\"", 1_000)

      assert completed_stream =~ "\"taskId\":\"#{task_id}\""
    after
      close_session_stream(socket, server_name, session_id, session_pid, 10_001)
    end
  end

  test "GET resumes missed events by id without crossing sessions" do
    server_name = "http-session-resume-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name), session_idle_ttl: :infinity)

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name, json_response: true)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    {:ok, socket, %{status: 200}, stream_state} = open_session_stream(port, session_id)

    first = replay_notification(1)
    assert {:ok, %{event_id: first_id}} = Session.send_envelope(server_name, session_id, first)

    assert {:ok, first_stream, _stream_state} =
             recv_stream_until(socket, stream_state, "\"sequence\":1", 1_000)

    assert first_stream =~ "id: #{first_id}\n"

    :ok = :inet.setopts(socket, linger: {true, 0})
    :ok = :gen_tcp.close(socket)

    second = replay_notification(2)
    assert {:ok, %{event_id: second_id}} = Session.send_envelope(server_name, session_id, second)

    assert_eventually(fn ->
      :sys.get_state(session_pid).sinks
      |> Map.values()
      |> Enum.all?(&(&1.kind != :get))
    end)

    third = replay_notification(3)

    assert {:ok, %{queued: true}} =
             Session.send_envelope(server_name, session_id, third, queue: true)

    {:ok, resumed_socket, %{status: 200}, resumed_state} =
      open_session_stream(port, session_id, first_id)

    try do
      assert {:ok, resumed_stream, _resumed_state} =
               recv_stream_until(resumed_socket, resumed_state, "\"sequence\":3", 1_000)

      refute resumed_stream =~ "\"sequence\":1"
      assert resumed_stream =~ "\"sequence\":2"
      assert resumed_stream =~ "\"sequence\":3"

      assert [[^second_id], [cursor_id], [third_id]] =
               Regex.scan(~r/^id: ([^\n]+)$/m, resumed_stream, capture: :all_but_first)

      refute cursor_id == second_id
      refute third_id == second_id
      refute third_id == cursor_id
    after
      close_session_stream(resumed_socket, server_name, session_id, session_pid, 4)
    end

    {:ok, repeated_socket, %{status: 200}, repeated_state} =
      open_session_stream(port, session_id, first_id)

    try do
      assert {:ok, %{event_id: repeated_live_id}} =
               Session.send_envelope(server_name, session_id, replay_notification(5))

      assert {:ok, repeated_stream, _repeated_state} =
               recv_stream_until(repeated_socket, repeated_state, "\"sequence\":5", 1_000)

      assert repeated_stream =~ "id: #{repeated_live_id}\n"
      assert repeated_stream =~ "\"sequence\":2"
      assert repeated_stream =~ "\"sequence\":3"
      assert repeated_stream =~ "\"sequence\":4"
    after
      close_session_stream(repeated_socket, server_name, session_id, session_pid, 6)
    end

    other_session_id = initialize_session(port)
    {:ok, other_session_pid} = Registry.lookup_session(server_name, other_session_id)

    {:ok, foreign_socket, %{status: 400}, _foreign_state} =
      open_session_stream(port, other_session_id, first_id)

    :ok = :gen_tcp.close(foreign_socket)

    {:ok, malformed_socket, %{status: 400}, _malformed_state} =
      open_session_stream(port, other_session_id, "not-an-event-id")

    :ok = :gen_tcp.close(malformed_socket)

    {:ok, other_socket, %{status: 200}, other_state} =
      open_session_stream(port, other_session_id)

    try do
      assert {:ok, %{event_id: other_id}} =
               Session.send_envelope(server_name, other_session_id, replay_notification(99))

      assert {:ok, other_stream, _other_state} =
               recv_stream_until(other_socket, other_state, "\"sequence\":99", 1_000)

      assert other_stream =~ "id: #{other_id}\n"
      refute other_stream =~ "\"sequence\":2"
      refute other_stream =~ "\"sequence\":3"
      refute other_id == first_id
    after
      close_session_stream(
        other_socket,
        server_name,
        other_session_id,
        other_session_pid,
        100
      )
    end
  end

  test "GET returns gone when a valid event id has fallen out of replay retention" do
    server_name = "http-session-evicted-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name),
               session_idle_ttl: :infinity,
               sse_replay_max_events: 1
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name, json_response: true)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    {:ok, socket, %{status: 200}, stream_state} = open_session_stream(port, session_id)

    assert {:ok, %{event_id: first_id}} =
             Session.send_envelope(server_name, session_id, replay_notification(1))

    assert {:ok, first_stream, _stream_state} =
             recv_stream_until(socket, stream_state, "\"sequence\":1", 1_000)

    assert first_stream =~ "id: #{first_id}\n"

    :ok = :inet.setopts(socket, linger: {true, 0})
    :ok = :gen_tcp.close(socket)

    assert {:ok, %{event_id: _second_id}} =
             Session.send_envelope(server_name, session_id, replay_notification(2))

    assert_eventually(fn ->
      :sys.get_state(session_pid).sinks
      |> Map.values()
      |> Enum.all?(&(&1.kind != :get))
    end)

    {:ok, gone_socket, %{status: 410}, _gone_state} =
      open_session_stream(port, session_id, first_id)

    :ok = :gen_tcp.close(gone_socket)
  end

  test "GET still returns gone after an earlier operation pruned the event's stream" do
    server_name = "http-session-pruned-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name),
               session_idle_ttl: :infinity,
               sse_replay_ttl_ms: 10
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name, json_response: true)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    {:ok, socket, %{status: 200}, stream_state} = open_session_stream(port, session_id)

    assert {:ok, %{event_id: first_id}} =
             Session.send_envelope(server_name, session_id, replay_notification(1))

    assert {:ok, _first_stream, _stream_state} =
             recv_stream_until(socket, stream_state, "\"sequence\":1", 1_000)

    close_session_stream(socket, server_name, session_id, session_pid, 2)
    Process.sleep(20)

    # Opening a fresh stream performs age eviction before the later resume.
    {:ok, fresh_socket, %{status: 200}, _fresh_state} =
      open_session_stream(port, session_id)

    close_session_stream(fresh_socket, server_name, session_id, session_pid, 3)

    {:ok, gone_socket, %{status: 410}, _gone_state} =
      open_session_stream(port, session_id, first_id)

    :ok = :gen_tcp.close(gone_socket)
  end

  test "GET does not receive an event that cannot be persisted for replay" do
    server_name = "http-session-unretained-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name),
               session_idle_ttl: :infinity,
               sse_replay_max_total_bytes: 1
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name, json_response: true)
    session_id = initialize_session(port)
    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    {:ok, socket, %{status: 200}, _stream_state} = open_session_stream(port, session_id)

    try do
      assert {:error, :sse_replay_unavailable} =
               Session.send_envelope(server_name, session_id, replay_notification(1))

      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
      assert :sys.get_state(session_pid).replay.total_bytes == 0
    after
      :ok = :gen_tcp.close(socket)
    end
  end

  test "tasks/result streams elicitation requests and the final task result" do
    parent = self()
    server_name = "http-task-result-stream-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _arguments, ctx ->
          send(parent, {:task_result_started, ctx.session_id})

          case Context.elicit(ctx, "What is your name?", :string) do
            %Accepted{data: name} -> %{name: name}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    port = start_http(server_name)
    session_id = initialize_session(port, %{"elicitation" => %{"form" => %{}}})

    create_response =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(10, "tools/call", %{
          "name" => "ask_name",
          "arguments" => %{},
          "task" => %{}
        }),
        session_id
      )

    assert create_response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 10,
             "result" => %{"task" => %{"taskId" => task_id}}
           } = sse_json(create_response.body)

    assert_receive {:task_result_started, ^session_id}, 1_000

    result_payload = ProtocolTest.jsonrpc_request(11, "tasks/result", %{"taskId" => task_id})

    {:ok, result_socket, result_response, result_stream_state} =
      open_post_stream(port, result_payload, session_id)

    try do
      assert result_response.status == 200
      assert Map.get(result_response.headers, "content-type") == "text/event-stream"

      assert {:ok, relay_stream, result_stream_state} =
               recv_stream_until(
                 result_socket,
                 result_stream_state,
                 "\"method\":\"elicitation/create\"",
                 1_000
               )

      assert relay_stream =~ "\"taskId\":\"#{task_id}\""
      assert relay_stream =~ "\"status\":\"input_required\""

      [_, relay_request_id] = Regex.run(~r/"id":"([^"]+)"/, relay_stream)

      callback_response =
        post_json(
          port,
          %{
            "jsonrpc" => "2.0",
            "id" => relay_request_id,
            "result" => %{
              "action" => "accept",
              "content" => %{"value" => "Alice"}
            }
          },
          session_id
        )

      assert callback_response.status == 202

      assert {:ok, final_stream, _result_stream_state} =
               recv_stream_until(
                 result_socket,
                 result_stream_state,
                 "\"structuredContent\":{\"name\":\"Alice\"}",
                 1_000
               )

      assert final_stream =~ "\"jsonrpc\":\"2.0\""
    after
      :gen_tcp.close(result_socket)
    end
  end

  defp start_http(server_name, opts \\ []) do
    plug_opts =
      [
        server_name: server_name,
        allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]
      ]
      |> Keyword.merge(opts)

    bandit =
      start_supervised!(
        {Bandit, plug: {FastestMCP.Transport.HTTPApp, plug_opts}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  defp initialize_session(port, capabilities \\ %{}) do
    initialize_response =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(
          1,
          "initialize",
          ProtocolTest.initialize_params(%{"capabilities" => capabilities})
        )
      )

    assert initialize_response.status == 200
    session_id = Map.fetch!(initialize_response.headers, "mcp-session-id")

    initialized_response =
      post_json(
        port,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized_response.status == 202
    session_id
  end

  defp post_json(port, payload, session_id \\ nil) do
    request(port, post_payload(payload, session_id, "close"))
  end

  defp open_post_stream(port, payload, session_id) do
    open_stream(port, post_payload(payload, session_id, "keep-alive"))
  end

  defp post_payload(payload, session_id, connection) do
    body = JSON.encode!(payload)

    [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Accept: application/json, text/event-stream\r\n",
      session_headers(session_id),
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: ",
      connection,
      "\r\n\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp open_session_stream(port, session_id, last_event_id \\ nil) do
    open_stream(
      port,
      [
        "GET /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Accept: text/event-stream\r\n",
        session_headers(session_id),
        last_event_id_header(last_event_id),
        "Connection: keep-alive\r\n\r\n"
      ]
      |> IO.iodata_to_binary()
    )
  end

  defp last_event_id_header(nil), do: []
  defp last_event_id_header(last_event_id), do: ["Last-Event-ID: ", last_event_id, "\r\n"]

  defp session_headers(nil), do: []

  defp session_headers(session_id) do
    [
      "MCP-Session-Id: ",
      session_id,
      "\r\n",
      "MCP-Protocol-Version: ",
      ProtocolTest.protocol_version(),
      "\r\n"
    ]
  end

  defp sse_json(body) do
    [json | _rest] = Regex.run(~r/data: ([^\n]+)/, body, capture: :all_but_first)
    JSON.decode!(json)
  end

  defp request(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    parse_http_response(response)
  end

  defp open_stream(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, head, rest} = recv_http_head(socket, "")
    response = parse_http_head(head)
    {decoded, raw} = decode_available_chunked_body(rest)
    {:ok, socket, response, %{decoded: decoded, raw: raw}}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end

  defp recv_http_head(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {:ok, head, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, chunk} -> recv_http_head(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_http_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    response = parse_http_head(head)

    Map.put(response, :body, maybe_decode_http_body(response.headers, body))
  end

  defp parse_http_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers}
  end

  defp decode_chunked_body(body), do: decode_chunked_body(body, "")

  defp decode_chunked_body("0\r\n\r\n", acc), do: acc

  defp decode_chunked_body(body, acc) do
    [size_hex, rest] = String.split(body, "\r\n", parts: 2)
    {size, ""} = Integer.parse(size_hex, 16)
    <<chunk::binary-size(^size), "\r\n", remainder::binary>> = rest
    decode_chunked_body(remainder, acc <> chunk)
  end

  defp maybe_decode_http_body(headers, body) do
    if Map.get(headers, "transfer-encoding") == "chunked" do
      decode_chunked_body(body)
    else
      body
    end
  end

  defp recv_stream_until(socket, %{decoded: decoded, raw: raw}, pattern, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_recv_stream_until(socket, decoded, raw, pattern, deadline)
  end

  defp recv_stream_tail(socket, stream_state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_recv_stream_tail(socket, stream_state, deadline)
  end

  defp do_recv_stream_tail(socket, %{decoded: decoded, raw: raw} = stream_state, deadline) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 1)

    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, chunk} ->
        {decoded, raw} = decode_available_chunked_body(raw <> chunk, decoded)
        do_recv_stream_tail(socket, %{stream_state | decoded: decoded, raw: raw}, deadline)

      {:error, reason} when reason in [:closed, :timeout] ->
        decoded
    end
  end

  defp do_recv_stream_until(socket, decoded, raw, pattern, deadline) do
    if String.contains?(decoded, pattern) do
      {:ok, decoded, %{decoded: decoded, raw: raw}}
    else
      timeout_ms = max(deadline - System.monotonic_time(:millisecond), 1)

      case :gen_tcp.recv(socket, 0, timeout_ms) do
        {:ok, chunk} ->
          {decoded, raw} = decode_available_chunked_body(raw <> chunk, decoded)
          do_recv_stream_until(socket, decoded, raw, pattern, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_available_chunked_body(body), do: decode_available_chunked_body(body, "")

  defp decode_available_chunked_body("", acc), do: {acc, ""}

  defp decode_available_chunked_body(body, acc) do
    case String.split(body, "\r\n", parts: 2) do
      [size_hex, rest] ->
        case Integer.parse(size_hex, 16) do
          {0, ""} ->
            {acc, ""}

          {size, ""} when byte_size(rest) >= size + 2 ->
            <<chunk::binary-size(^size), "\r\n", remainder::binary>> = rest
            decode_available_chunked_body(remainder, acc <> chunk)

          _other ->
            {acc, body}
        end

      [_incomplete] ->
        {acc, body}
    end
  end

  defp replay_notification(sequence) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/replay-test",
      "params" => %{"sequence" => sequence}
    }
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp close_session_stream(socket, server_name, session_id, session_pid, sequence) do
    _ = :inet.setopts(socket, linger: {true, 0})
    :ok = :gen_tcp.close(socket)
    _ = Session.send_envelope(server_name, session_id, replay_notification(sequence))

    assert_eventually(fn ->
      :sys.get_state(session_pid).sinks
      |> Map.values()
      |> Enum.all?(&(&1.kind != :get))
    end)
  end
end
