defmodule FastestMCP.HTTPContextTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Context
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "context exposes a normalized HTTP request snapshot across tools prompts and resources" do
    server_name =
      "http-request-snapshot-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("request_tool", fn _args, ctx -> http_request_payload(ctx) end)
      |> FastestMCP.add_prompt("request_prompt", fn _args, ctx ->
        inspect(http_request_payload(ctx))
      end)
      |> FastestMCP.add_resource("request://snapshot", fn _args, ctx ->
        http_request_payload(ctx)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    request_metadata = %{
      method: "POST",
      path: "/mcp",
      query_params: %{"demo" => "1"},
      headers: %{
        "X-Demo-Header" => "ABC",
        "Authorization" => "Bearer request-token"
      }
    }

    assert %{
             method: "POST",
             path: "/mcp",
             query_params: %{"demo" => "1"},
             headers: %{
               "authorization" => "Bearer request-token",
               "x-demo-header" => "ABC"
             }
           } ==
             FastestMCP.call_tool(server_name, "request_tool", %{},
               request_metadata: request_metadata
             )

    prompt_result =
      FastestMCP.render_prompt(server_name, "request_prompt", %{},
        request_metadata: request_metadata
      )

    assert prompt_result.messages |> List.first() |> Map.fetch!(:content) =~ "x-demo-header"

    assert %{
             method: "POST",
             path: "/mcp",
             query_params: %{"demo" => "1"},
             headers: %{
               "authorization" => "Bearer request-token",
               "x-demo-header" => "ABC"
             }
           } ==
             FastestMCP.read_resource(server_name, "request://snapshot",
               request_metadata: request_metadata
             )
  end

  test "http_headers excludes problematic headers by default and background tasks keep the snapshot" do
    server_name = "http-headers-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "headers",
        fn _args, ctx ->
          %{
            filtered: Context.http_headers(ctx),
            all: Context.http_headers(ctx, include_all: true),
            access_token: Context.access_token(ctx),
            method: Context.http_request(ctx).method
          }
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    task =
      FastestMCP.call_tool(server_name, "headers", %{},
        task: true,
        session_id: "http-task-session",
        request_metadata: %{
          method: "POST",
          path: "/mcp",
          headers: %{
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "Host" => "example.test",
            "Content-Length" => "42",
            "Authorization" => "Bearer tenant-token",
            "X-Tenant-ID" => "tenant-123"
          }
        }
      )

    assert %{
             access_token: "tenant-token",
             method: "POST",
             filtered: %{
               "authorization" => "Bearer tenant-token",
               "x-tenant-id" => "tenant-123"
             },
             all: %{
               "accept" => "application/json",
               "authorization" => "Bearer tenant-token",
               "content-length" => "42",
               "content-type" => "application/json",
               "host" => "example.test",
               "x-tenant-id" => "tenant-123"
             }
           } == FastestMCP.await_task(task, 1_000)
  end

  test "streamable HTTP transport populates the HTTP request snapshot" do
    server_name =
      "http-request-transport-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("inspect_headers", fn _args, ctx ->
        %{
          request: http_request_payload(ctx),
          filtered_headers: Context.http_headers(ctx)
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    conn =
      conn(
        :post,
        "/mcp?demo=1",
        JSON.encode!(
          ProtocolTest.jsonrpc_request(2, "tools/call", %{
            "name" => "inspect_headers",
            "arguments" => %{}
          })
        )
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("x-demo-header", "ABC")
      |> put_req_header("authorization", "Bearer fresh-token")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name, json_response: true)

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{
               "structuredContent" => %{
                 "request" => %{
                   "method" => "POST",
                   "path" => "/mcp",
                   "query_params" => %{"demo" => "1"},
                   "headers" => %{
                     "authorization" => "Bearer fresh-token",
                     "content-type" => "application/json",
                     "x-demo-header" => "ABC"
                   }
                 },
                 "filtered_headers" => %{
                   "authorization" => "Bearer fresh-token",
                   "x-demo-header" => "ABC"
                 }
               }
             }
           } = JSON.decode!(conn.resp_body)
  end

  defp http_request_payload(ctx) do
    request = Context.http_request(ctx)

    %{
      method: request.method,
      path: request.path,
      query_params: request.query_params,
      headers: request.headers
    }
  end
end
