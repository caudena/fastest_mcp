defmodule FastestMCP.StreamableHTTPGetRegressionTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

  # Regression: ISSUE-QA-001 — GET /mcp returned 501 not_implemented instead of reaching the session layer
  # Found by /qa on 2026-04-10
  # Report: .gstack/qa-reports/qa-report-localhost-4100-2026-04-10.md

  test "GET /mcp requires event-stream negotiation and an existing session" do
    server_name = "http-get-session-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    missing_accept =
      conn(:get, "/mcp")
      |> Map.put(:host, "localhost")
      |> StreamableHTTP.call(server_name: server_name)

    assert missing_accept.status == 406

    assert %{
             "error" => %{
               "message" => "MCP GET requires text/event-stream"
             }
           } = JSON.decode!(missing_accept.resp_body)

    unacceptable =
      conn(:get, "/mcp")
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("accept", "text/event-stream;q=0")
      |> StreamableHTTP.call(server_name: server_name)

    assert unacceptable.status == 406

    unknown_session =
      conn(:get, "/mcp")
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> Plug.Conn.put_req_header("mcp-session-id", "client-invented-session")
      |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(server_name: server_name)

    assert unknown_session.status == 404

    body = JSON.decode!(unknown_session.resp_body)
    assert %{"jsonrpc" => "2.0", "error" => %{"message" => message}} = body
    refute Map.has_key?(body, "id")

    assert message =~ "unknown session"
  end

  test "GET /mcp returns 405 when session streaming is explicitly disabled" do
    server_name = "http-get-disabled-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    response =
      conn(:get, "/mcp")
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> StreamableHTTP.call(server_name: server_name, enable_get_streaming: false)

    assert response.status == 405
    assert Plug.Conn.get_resp_header(response, "allow") == ["POST, DELETE"]

    assert %{
             "error" => %{
               "code" => "method_not_allowed",
               "message" => "GET streaming is disabled"
             }
           } = JSON.decode!(response.resp_body)
  end

  test "GET streaming configuration requires a boolean" do
    assert_raise ArgumentError, ~r/:enable_get_streaming must be a boolean/, fn ->
      StreamableHTTP.init(enable_get_streaming: :sometimes)
    end
  end
end
