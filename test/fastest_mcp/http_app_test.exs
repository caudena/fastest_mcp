defmodule FastestMCP.HTTPAppTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "http app applies custom middleware to custom routes" do
    server_name = "http-app-routes-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-custom-header", "test-value"))
            |> next.()
          end
        ],
        routes: [
          {:get, "/test", fn conn -> json(conn, 200, %{message: "Hello, world!"}) end}
        ]
      )

    response = conn(:get, "/test") |> app.()

    assert response.status == 200
    assert get_resp_header(response, "x-custom-header") == ["test-value"]
    assert Jason.decode!(response.resp_body) == %{"message" => "Hello, world!"}
  end

  test "http app middleware can modify request state for custom routes" do
    server_name = "http-app-state-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        middleware: [
          fn conn, next ->
            conn
            |> assign(:custom_value, %{"modified_by" => "middleware"})
            |> next.()
          end
        ],
        routes: [
          {:get, "/test", fn conn -> json(conn, 200, %{state: conn.assigns.custom_value}) end}
        ]
      )

    response = conn(:get, "/test") |> app.()

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"state" => %{"modified_by" => "middleware"}}
  end

  test "http app middleware also wraps MCP transport routes" do
    server_name = "http-app-mcp-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    app =
      FastestMCP.http_app(server_name,
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-transport-middleware", "applied"))
            |> next.()
          end
        ]
      )

    response =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "echo", "arguments" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> app.()

    assert response.status == 200
    assert get_resp_header(response, "x-transport-middleware") == ["applied"]

    assert %{
             "content" => [%{"type" => "text", "text" => "{}"}],
             "structuredContent" => %{}
           } = Jason.decode!(response.resp_body)
  end

  test "http app forwards stateless streamable HTTP options to the transport" do
    server_name = "http-app-stateless-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    app = FastestMCP.http_app(server_name, stateless_http: true)

    get_response = conn(:get, "/mcp") |> app.()
    assert get_response.status == 405

    post_response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> app.()

    assert post_response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 9,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{\"message\":\"hi\"}"}],
               "structuredContent" => %{"message" => "hi"}
             }
           } = Jason.decode!(post_response.resp_body)
  end

  test "http app can reject non-local host and origin headers when allowed_hosts is configured" do
    server_name = "http-app-host-guard-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app = FastestMCP.http_app(server_name, allowed_hosts: :localhost)

    blocked =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"clientInfo" => %{"name" => "dns-test"}}
        })
      )
      |> Map.put(:host, "evil.example.com")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://evil.example.com")
      |> app.()

    assert blocked.status == 403

    allowed =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => %{"clientInfo" => %{"name" => "dns-test"}}
        })
      )
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://127.0.0.1:4000")
      |> app.()

    assert allowed.status == 200
  end

  test "http app applies multiple middleware in order" do
    server_name = "http-app-order-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-first-header", "first"))
            |> next.()
          end,
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-second-header", "second"))
            |> next.()
          end
        ],
        routes: [
          {"GET", "/test", fn conn -> json(conn, 200, %{message: "ok"}) end}
        ]
      )

    response = conn(:get, "/test") |> app.()

    assert response.status == 200
    assert get_resp_header(response, "x-first-header") == ["first"]
    assert get_resp_header(response, "x-second-header") == ["second"]
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
