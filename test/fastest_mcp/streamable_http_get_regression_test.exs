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
      |> StreamableHTTP.call(server_name: server_name)

    assert missing_accept.status == 400

    assert %{
             "error" => %{
               "message" => "MCP GET requires text/event-stream"
             }
           } = JSON.decode!(missing_accept.resp_body)

    unknown_session =
      conn(:get, "/mcp")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> Plug.Conn.put_req_header("mcp-session-id", "client-invented-session")
      |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(server_name: server_name)

    assert unknown_session.status == 404

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"message" => message}
           } = JSON.decode!(unknown_session.resp_body)

    assert message =~ "unknown session"
  end
end
