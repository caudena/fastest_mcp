defmodule FastestMCP.StreamableHTTPEventStreamTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted

  test "streamable HTTP uses event-stream framing for streamed tool calls" do
    server_name = "http-event-stream-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FastestMCP.Transport.HTTPApp, server_name: server_name, allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    request_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
      })

    response =
      request(
        port,
        [
          "POST /mcp HTTP/1.1\r\n",
          "Host: 127.0.0.1\r\n",
          "Content-Type: application/json\r\n",
          "Accept: text/event-stream\r\n",
          "mcp-session-id: event-stream-session\r\n",
          "Content-Length: ",
          Integer.to_string(byte_size(request_body)),
          "\r\n",
          "Connection: close\r\n\r\n",
          request_body
        ]
        |> IO.iodata_to_binary()
      )

    assert response.status == 200
    assert Map.get(response.headers, "content-type") == "text/event-stream"
    assert Map.get(response.headers, "mcp-session-id") == "event-stream-session"
    assert response.body =~ "event: message\n"
    assert response.body =~ "\"jsonrpc\":\"2.0\""
    assert response.body =~ "\"structuredContent\":{\"message\":\"hi\"}"
  end

  test "GET session event streams relay task notifications for the same session" do
    parent = self()
    server_name = "http-session-stream-" <> Integer.to_string(System.unique_integer([:positive]))

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

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FastestMCP.Transport.HTTPApp, server_name: server_name, allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    {:ok, socket, response, stream_state} =
      open_stream(
        port,
        [
          "GET /mcp HTTP/1.1\r\n",
          "Host: 127.0.0.1\r\n",
          "Accept: text/event-stream\r\n",
          "mcp-session-id: task-stream-session\r\n",
          "Connection: keep-alive\r\n\r\n"
        ]
        |> IO.iodata_to_binary()
      )

    try do
      assert response.status == 200
      assert Map.get(response.headers, "content-type") == "text/event-stream"
      assert Map.get(response.headers, "mcp-session-id") == "task-stream-session"

      request_body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "wait", "arguments" => %{}, "task" => true}
        })

      task_response =
        request(
          port,
          [
            "POST /mcp HTTP/1.1\r\n",
            "Host: 127.0.0.1\r\n",
            "Content-Type: application/json\r\n",
            "Accept: application/json\r\n",
            "mcp-session-id: task-stream-session\r\n",
            "Content-Length: ",
            Integer.to_string(byte_size(request_body)),
            "\r\n",
            "Connection: close\r\n\r\n",
            request_body
          ]
          |> IO.iodata_to_binary()
        )

      assert task_response.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => 9,
               "result" => %{"task" => %{"taskId" => task_id, "status" => "working"}}
             } = Jason.decode!(task_response.body)

      assert_receive {:session_stream_task_started, "task-stream-session", task_pid}, 1_000

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

  test "legacy tasks/result requests stream elicitation relay events when event-stream is accepted" do
    parent = self()

    server_name =
      "http-legacy-task-result-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _arguments, ctx ->
          send(parent, {:legacy_task_result_started, ctx.session_id})

          case Context.elicit(ctx, "What is your name?", :string) do
            %Accepted{data: name} -> %{name: name}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FastestMCP.Transport.HTTPApp, server_name: server_name, allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    {:ok, session_socket, session_response, _session_stream_state} =
      open_stream(
        port,
        [
          "GET /mcp HTTP/1.1\r\n",
          "Host: 127.0.0.1\r\n",
          "Accept: text/event-stream\r\n",
          "mcp-session-id: legacy-task-result-session\r\n",
          "Connection: keep-alive\r\n\r\n"
        ]
        |> IO.iodata_to_binary()
      )

    task_result_body =
      try do
        assert session_response.status == 200
        assert Map.get(session_response.headers, "content-type") == "text/event-stream"

        create_body =
          Jason.encode!(%{
            "name" => "ask_name",
            "arguments" => %{},
            "task" => true
          })

        create_response =
          request(
            port,
            [
              "POST /mcp/tools/call HTTP/1.1\r\n",
              "Host: 127.0.0.1\r\n",
              "Content-Type: application/json\r\n",
              "Accept: application/json\r\n",
              "x-fastestmcp-session: legacy-task-result-session\r\n",
              "Content-Length: ",
              Integer.to_string(byte_size(create_body)),
              "\r\n",
              "Connection: close\r\n\r\n",
              create_body
            ]
            |> IO.iodata_to_binary()
          )

        assert create_response.status == 200

        assert %{"task" => %{"taskId" => task_id}} = Jason.decode!(create_response.body)
        assert_receive {:legacy_task_result_started, "legacy-task-result-session"}, 1_000

        result_body = Jason.encode!(%{"taskId" => task_id})

        {:ok, result_socket, result_response, result_stream_state} =
          open_stream(
            port,
            [
              "POST /mcp/tasks/result HTTP/1.1\r\n",
              "Host: 127.0.0.1\r\n",
              "Content-Type: application/json\r\n",
              "Accept: application/json, text/event-stream\r\n",
              "x-fastestmcp-session: legacy-task-result-session\r\n",
              "Content-Length: ",
              Integer.to_string(byte_size(result_body)),
              "\r\n",
              "Connection: keep-alive\r\n\r\n",
              result_body
            ]
            |> IO.iodata_to_binary()
          )

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

          callback_body =
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => relay_request_id,
              "result" => %{
                "action" => "accept",
                "content" => %{"value" => "Alice"}
              }
            })

          callback_response =
            request(
              port,
              [
                "POST /mcp HTTP/1.1\r\n",
                "Host: 127.0.0.1\r\n",
                "Content-Type: application/json\r\n",
                "Accept: application/json\r\n",
                "x-fastestmcp-session: legacy-task-result-session\r\n",
                "Content-Length: ",
                Integer.to_string(byte_size(callback_body)),
                "\r\n",
                "Connection: close\r\n\r\n",
                callback_body
              ]
              |> IO.iodata_to_binary()
            )

          assert callback_response.status == 202

          assert {:ok, final_stream, _result_stream_state} =
                   recv_stream_until(
                     result_socket,
                     result_stream_state,
                     "\"structuredContent\":{\"name\":\"Alice\"}",
                     1_000
                   )

          final_stream
        after
          :gen_tcp.close(result_socket)
        end
      after
        :gen_tcp.close(session_socket)
      end

    assert task_result_body =~ "\"jsonrpc\":\"2.0\""
    assert task_result_body =~ "\"structuredContent\":{\"name\":\"Alice\"}"
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

    %{
      status: String.to_integer(status),
      headers: headers
    }
  end

  defp decode_chunked_body(body), do: decode_chunked_body(body, "")

  defp decode_chunked_body("0\r\n\r\n", acc), do: acc

  defp decode_chunked_body(body, acc) do
    [size_hex, rest] = String.split(body, "\r\n", parts: 2)
    {size, ""} = Integer.parse(size_hex, 16)
    <<chunk::binary-size(size), "\r\n", remainder::binary>> = rest
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
            <<chunk::binary-size(size), "\r\n", remainder::binary>> = rest
            decode_available_chunked_body(remainder, acc <> chunk)

          _other ->
            {acc, body}
        end

      [_incomplete] ->
        {acc, body}
    end
  end
end
