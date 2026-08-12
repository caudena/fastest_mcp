defmodule FastestMCP.StreamableHTTPRegression1Test do
  use ExUnit.Case, async: false

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  # Regression: ISSUE-001 — HTTP transport crashed before MCP handlers ran
  # Found by /qa on 2026-04-09
  # Report: .gstack/qa-reports/qa-report-localhost-4100-2026-04-09.md

  test "live JSON-RPC initialization, listing, and calls work through Bandit" do
    server_name = "http-regression-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
            json_response: true},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    initialize =
      post_request(
        port,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      )

    assert initialize.status == 200
    session_id = Map.fetch!(initialize.headers, "mcp-session-id")

    initialized =
      post_request(
        port,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized.status == 202

    tools = post_request(port, ProtocolTest.jsonrpc_request(2, "tools/list"), session_id)
    assert tools.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"tools" => [%{"name" => "echo"}]}} =
             JSON.decode!(tools.body)

    call =
      post_request(
        port,
        ProtocolTest.jsonrpc_request(3, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"message" => "hi"}
        }),
        session_id
      )

    assert call.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "result" => %{"structuredContent" => %{"message" => "hi"}}
           } = JSON.decode!(call.body)
  end

  defp post_request(port, payload, session_id \\ nil) do
    body = JSON.encode!(payload)

    headers = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Accept: application/json, text/event-stream\r\n",
      maybe_session_headers(session_id),
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    request(port, IO.iodata_to_binary(headers))
  end

  defp maybe_session_headers(nil), do: []

  defp maybe_session_headers(session_id) do
    [
      "MCP-Session-Id: ",
      session_id,
      "\r\n",
      "MCP-Protocol-Version: ",
      ProtocolTest.protocol_version(),
      "\r\n"
    ]
  end

  defp request(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
