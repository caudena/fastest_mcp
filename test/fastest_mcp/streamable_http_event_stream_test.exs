defmodule FastestMCP.StreamableHTTPEventStreamTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
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
    assert response.body =~ ~r/\Aid: \d+\nevent: message\ndata: \n\n/
    assert response.body =~ "event: message\n"
    assert response.body =~ "\"jsonrpc\":\"2.0\""
    assert response.body =~ "\"structuredContent\":{\"message\":\"hi\"}"
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
      :gen_tcp.close(socket)
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
    session_id = initialize_session(port)

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
      [server_name: server_name, unsafe_allow_any_host: true]
      |> Keyword.merge(opts)

    bandit =
      start_supervised!(
        {Bandit, plug: {FastestMCP.Transport.HTTPApp, plug_opts}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  defp initialize_session(port) do
    initialize_response =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
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

  defp open_session_stream(port, session_id) do
    open_stream(
      port,
      [
        "GET /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Accept: text/event-stream\r\n",
        session_headers(session_id),
        "Connection: keep-alive\r\n\r\n"
      ]
      |> IO.iodata_to_binary()
    )
  end

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
end
