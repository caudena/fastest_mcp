defmodule FastestMCP.StreamableHTTPSingleEndpointTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

  setup do
    server_name = "http-endpoint-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    %{server_name: server_name}
  end

  test "POST /mcp accepts one JSON-RPC request after initialization", %{server_name: server_name} do
    {session_id, initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialize_response.status == 200
    assert initialized_response.status == 202

    response =
      ProtocolTest.http_request(
        server_name,
        session_id,
        7,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "hi"}}
      )

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{\"message\":\"hi\"}"}],
               "structuredContent" => %{"message" => "hi"}
             }
           } = JSON.decode!(response.resp_body)
  end

  test "only the exact configured MCP path is routed", %{server_name: server_name} do
    response =
      conn(:get, "/mcp/")
      |> StreamableHTTP.call(server_name: server_name)

    assert response.status == 404

    assert %{"error" => %{"code" => "not_found", "message" => "unknown route"}} =
             JSON.decode!(response.resp_body)
  end

  test "initialize returns a server-issued URL-safe MCP session id", %{server_name: server_name} do
    {session_id, response} = ProtocolTest.http_initialize(server_name)

    assert response.status == 200
    assert session_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"protocolVersion" => protocol_version}
           } = JSON.decode!(response.resp_body)

    assert protocol_version == ProtocolTest.protocol_version()
  end

  test "initialize ignores query-string session ids and only uses the session header", %{
    server_name: server_name
  } do
    initialize_response =
      conn(
        :post,
        "/mcp?session_id=spoofed-session",
        JSON.encode!(
          ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
        )
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> StreamableHTTP.call(server_name: server_name)

    assert initialize_response.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialize_response, "mcp-session-id")
    refute session_id == "spoofed-session"
    assert session_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/

    delete_response =
      conn(:delete, "/mcp?session_id=#{session_id}")
      |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(server_name: server_name)

    assert delete_response.status == 400

    assert %{
             "error" => %{
               "message" => "MCP-Session-Id is required"
             }
           } = JSON.decode!(delete_response.resp_body)

    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    reuse_response =
      ProtocolTest.http_request(
        server_name,
        session_id,
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "hi"}}
      )

    assert reuse_response.status == 200
  end

  test "POST /mcp rejects JSON-RPC batches", %{server_name: server_name} do
    response =
      conn(
        :post,
        "/mcp",
        JSON.encode!([
          ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params()),
          ProtocolTest.jsonrpc_notification("notifications/initialized")
        ])
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> StreamableHTTP.call(server_name: server_name)

    assert response.status == 400
    assert Plug.Conn.get_resp_header(response, "mcp-session-id") == []

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_600,
               "message" => "JSON-RPC batch requests are not supported"
             }
           } = JSON.decode!(response.resp_body)
  end

  test "stateless streamable HTTP only allows POST", %{server_name: server_name} do
    response =
      conn(:get, "/mcp")
      |> StreamableHTTP.call(server_name: server_name, stateless_http: true)

    assert response.status == 405
    assert Plug.Conn.get_resp_header(response, "allow") == ["POST"]

    assert %{
             "error" => %{
               "code" => "method_not_allowed",
               "message" => "stateless HTTP only supports POST"
             }
           } = JSON.decode!(response.resp_body)
  end

  test "DELETE /mcp terminates a session and rejects later reuse", %{server_name: server_name} do
    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    delete_response =
      conn(:delete, "/mcp")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(server_name: server_name)

    assert delete_response.status == 204
    assert delete_response.resp_body == ""

    reuse_response =
      ProtocolTest.http_request(
        server_name,
        session_id,
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "hi"}}
      )

    assert reuse_response.status == 404

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{"message" => message}
           } = JSON.decode!(reuse_response.resp_body)

    assert message =~ "unknown session"
  end
end
