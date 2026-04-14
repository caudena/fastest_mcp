defmodule FastestMCP.StreamableHTTPRegression1Test do
  use ExUnit.Case, async: false

  # Regression: ISSUE-001 — HTTP transport crashed before MCP handlers ran
  # Found by /qa on 2026-04-09
  # Report: .gstack/qa-reports/qa-report-localhost-4100-2026-04-09.md

  test "live HTTP requests can list tools and call tools through Bandit" do
    server_name = "http-regression-" <> Integer.to_string(System.unique_integer([:positive]))
    port = 45_000 + rem(System.unique_integer([:positive]), 1000)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    start_supervised!(FastestMCP.streamable_http_child_spec(server_name, port: port))

    assert {200, body} =
             request(
               port,
               "GET /mcp/tools HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
             )

    assert %{"tools" => [%{"name" => "echo"}]} = Jason.decode!(body)

    request_body = Jason.encode!(%{"name" => "echo", "arguments" => %{"message" => "hi"}})

    request =
      [
        "POST /mcp/tools/call HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(request_body)),
        "\r\n",
        "Connection: close\r\n\r\n",
        request_body
      ]
      |> IO.iodata_to_binary()

    assert {200, call_body} = request(port, request)

    assert %{"structuredContent" => %{"message" => "hi"}} = Jason.decode!(call_body)
  end

  defp request(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    {String.to_integer(status), body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
