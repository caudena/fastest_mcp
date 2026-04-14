defmodule FastestMCP.StreamableHTTPGetRegressionTest do
  use ExUnit.Case, async: false

  import Plug.Test

  # Regression: ISSUE-QA-001 — GET /mcp returned 501 not_implemented instead of reaching the session layer
  # Found by /qa on 2026-04-10
  # Report: .gstack/qa-reports/qa-report-localhost-4100-2026-04-10.md

  test "GET /mcp establishes a session that can be reused by later JSON-RPC requests" do
    server_name = "http-get-session-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    get_response =
      conn(:get, "/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert get_response.status == 204
    [session_id] = Plug.Conn.get_resp_header(get_response, "mcp-session-id")
    assert session_id != ""

    call_response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "after-get"}}
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert call_response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{
               "structuredContent" => %{"message" => "after-get"}
             }
           } = Jason.decode!(call_response.resp_body)
  end
end
