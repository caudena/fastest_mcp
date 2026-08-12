defmodule FastestMCP.StreamableHTTPPhoenixIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

  test "streamable HTTP accepts JSON-RPC payloads from pre-parsed Phoenix body_params" do
    server_name = "phoenix-body-params-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
    }

    response =
      conn(:post, "/mcp", "")
      |> Map.put(:host, "localhost")
      |> Map.put(:body_params, payload)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{
               "structuredContent" => %{"message" => "hi"}
             }
           } = JSON.decode!(response.resp_body)
  end

  test "streamable HTTP infers the mounted path from script_name for forwarded plugs" do
    server_name =
      "phoenix-forwarded-path-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    initialize_response =
      forwarded_request(
        server_name,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      )

    assert initialize_response.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialize_response, "mcp-session-id")

    initialized_response =
      forwarded_request(
        server_name,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized_response.status == 202

    response =
      forwarded_request(
        server_name,
        ProtocolTest.jsonrpc_request(8, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"message" => "mounted"}
        }),
        session_id
      )

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 8,
             "result" => %{
               "structuredContent" => %{"message" => "mounted"}
             }
           } = JSON.decode!(response.resp_body)
  end

  test "streamable HTTP rejects pre-parsed JSON-RPC batches from Phoenix" do
    server_name =
      "phoenix-batch-body-params-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    parsed_conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!([
          ProtocolTest.jsonrpc_request(11, "initialize", ProtocolTest.initialize_params())
        ])
      )
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Parsers.call(
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["application/json"],
          json_decoder: JSON
        )
      )

    response =
      parsed_conn
      |> StreamableHTTP.call(server_name: server_name)

    assert response.status == 400
    assert Plug.Conn.get_resp_header(response, "mcp-session-id") == []

    body = JSON.decode!(response.resp_body)

    assert %{
             "jsonrpc" => "2.0",
             "error" => %{
               "code" => -32_600,
               "message" => "JSON-RPC batch requests are not supported"
             }
           } = body

    refute Map.has_key?(body, "id")
  end

  defp forwarded_request(server_name, payload, session_id \\ nil) do
    conn(:post, "/internal/mcp", JSON.encode!(payload))
    |> Map.put(:host, "localhost")
    |> Map.put(:script_name, ["internal", "mcp"])
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
    |> maybe_put_session_headers(session_id)
    |> StreamableHTTP.call(server_name: server_name, json_response: true)
  end

  defp maybe_put_session_headers(conn, nil), do: conn

  defp maybe_put_session_headers(conn, session_id) do
    conn
    |> Plug.Conn.put_req_header("mcp-session-id", session_id)
    |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
  end
end
