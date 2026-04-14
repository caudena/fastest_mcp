defmodule FastestMCP.StreamableHTTPPhoenixIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Protocol

  test "streamable HTTP accepts JSON-RPC payloads from pre-parsed Phoenix body_params" do
    server_name = "phoenix-body-params-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
    }

    response =
      conn(:post, "/mcp", "")
      |> Map.put(:body_params, payload)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", "phoenix-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{
               "structuredContent" => %{"message" => "hi"}
             }
           } = Jason.decode!(response.resp_body)
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

    response =
      conn(
        :post,
        "/internal/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "mounted"}}
        })
      )
      |> Map.put(:script_name, ["internal", "mcp"])
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", "forwarded-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 8,
             "result" => %{
               "structuredContent" => %{"message" => "mounted"}
             }
           } = Jason.decode!(response.resp_body)
  end

  test "streamable HTTP accepts JSON-RPC batch payloads from Phoenix JSON parser body_params" do
    server_name =
      "phoenix-batch-body-params-" <> Integer.to_string(System.unique_integer([:positive]))

    protocol_version = Protocol.current_version()

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    parsed_conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!([
          %{
            "jsonrpc" => "2.0",
            "id" => 11,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => protocol_version,
              "clientInfo" => %{"name" => "phoenix-client", "version" => "1.0.0"}
            }
          }
        ])
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["application/json"],
          json_decoder: Jason
        )
      )

    response =
      parsed_conn
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200
    [session_id] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    assert session_id != ""

    assert [
             %{
               "jsonrpc" => "2.0",
               "id" => 11,
               "result" => %{"protocolVersion" => ^protocol_version}
             }
           ] = Jason.decode!(response.resp_body)
  end
end
