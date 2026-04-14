defmodule FastestMCP.StreamableHTTPSingleEndpointTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Protocol

  test "streamable HTTP accepts JSON-RPC requests on the MCP base path" do
    server_name = "http-jsonrpc-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", "jsonrpc-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{\"message\":\"hi\"}"}],
               "structuredContent" => %{"message" => "hi"}
             }
           } = Jason.decode!(response.resp_body)
  end

  test "streamable HTTP redirects trailing slash requests to the canonical MCP path" do
    server_name = "http-redirect-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    response =
      conn(:get, "/mcp/")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 307
    assert Plug.Conn.get_resp_header(response, "location") == ["http://www.example.com/mcp"]
    assert response.resp_body == ""
  end

  test "initialize returns an MCP session header on the single endpoint" do
    server_name = "http-initialize-" <> Integer.to_string(System.unique_integer([:positive]))
    protocol_version = Protocol.current_version()
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => protocol_version,
            "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
          }
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200
    [session_id] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    assert session_id != ""
    assert session_id =~ ~r/\A[0-9a-f]{32}\z/

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"protocolVersion" => ^protocol_version}
           } = Jason.decode!(response.resp_body)
  end

  test "initialize ignores query-string session ids and only uses the session header" do
    server_name =
      "http-query-session-" <> Integer.to_string(System.unique_integer([:positive]))

    protocol_version = Protocol.current_version()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    initialize_response =
      conn(
        :post,
        "/mcp?session_id=spoofed-session",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => protocol_version,
            "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
          }
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert initialize_response.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialize_response, "mcp-session-id")
    refute session_id == "spoofed-session"
    assert session_id =~ ~r/\A[0-9a-f]{32}\z/

    delete_response =
      conn(:delete, "/mcp?session_id=#{session_id}")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert delete_response.status == 400

    assert %{
             "error" => %{
               "message" => "streamable HTTP session deletion requires mcp-session-id"
             }
           } = Jason.decode!(delete_response.resp_body)

    reuse_response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert reuse_response.status == 200
  end

  test "streamable HTTP accepts JSON-RPC batch requests on the MCP base path" do
    server_name = "http-jsonrpc-batch-" <> Integer.to_string(System.unique_integer([:positive]))
    protocol_version = Protocol.current_version()
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    response =
      conn(
        :post,
        "/mcp",
        Jason.encode!([
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => protocol_version,
              "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
            }
          },
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized",
            "params" => %{}
          }
        ])
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200
    [session_id] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    assert session_id != ""

    assert [
             %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{"protocolVersion" => ^protocol_version}
             }
           ] = Jason.decode!(response.resp_body)
  end

  test "stateless streamable HTTP rejects GET requests on the MCP base path" do
    server_name = "http-stateless-get-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    response =
      conn(:get, "/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name, stateless_http: true)

    assert response.status == 405
    assert Plug.Conn.get_resp_header(response, "allow") == ["POST, DELETE"]

    assert %{
             "error" => %{
               "code" => "method_not_allowed",
               "message" => "stateless streamable HTTP does not support GET"
             }
           } = Jason.decode!(response.resp_body)
  end

  test "DELETE /mcp terminates a session and rejects later reuse" do
    server_name = "http-delete-session-" <> Integer.to_string(System.unique_integer([:positive]))
    protocol_version = Protocol.current_version()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    initialize_response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => protocol_version,
            "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
          }
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    [session_id] = Plug.Conn.get_resp_header(initialize_response, "mcp-session-id")

    delete_response =
      conn(:delete, "/mcp")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert delete_response.status == 204
    assert delete_response.resp_body == ""

    reuse_response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert reuse_response.status == 404

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{"message" => message}
           } = Jason.decode!(reuse_response.resp_body)

    assert message =~ "unknown session"
  end
end
