defmodule FastestMCP.HTTPAppTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.HTTPApp

  test "http child spec defaults to loopback and forwards Bandit options" do
    server_name = "http-child-spec-#{System.unique_integer([:positive])}"
    forwarded_options = [startup_log: false, thousand_island_options: [num_acceptors: 3]]

    assert %{
             id: {HTTPApp, ^server_name, 4_101},
             start: {Bandit, :start_link, [bandit_options]}
           } =
             FastestMCP.streamable_http_child_spec(server_name,
               port: 4_101,
               bandit_options: forwarded_options
             )

    assert Keyword.fetch!(bandit_options, :ip) == :loopback
    assert Keyword.fetch!(bandit_options, :scheme) == :http
    assert Keyword.fetch!(bandit_options, :port) == 4_101
    assert Keyword.fetch!(bandit_options, :startup_log) == false
    assert Keyword.fetch!(bandit_options, :thousand_island_options) == [num_acceptors: 3]

    assert {HTTPApp, plug_options} = Keyword.fetch!(bandit_options, :plug)
    assert Keyword.fetch!(plug_options, :server_name) == server_name
    assert Keyword.fetch!(plug_options, :bandit_options) == forwarded_options
  end

  test "http child spec validates external listener host protection" do
    server_name = "http-external-listener-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError,
                 "external HTTP listeners require a concrete allowed_hosts list",
                 fn ->
                   FastestMCP.streamable_http_child_spec(server_name,
                     bandit_options: [ip: {0, 0, 0, 0}]
                   )
                 end

    for protection <- [
          [allowed_hosts: ["mcp.example.com"]],
          [unsafe_allow_any_host: true]
        ] do
      child_spec =
        FastestMCP.streamable_http_child_spec(
          server_name,
          Keyword.merge([bandit_options: [ip: {0, 0, 0, 0}]], protection)
        )

      assert %{start: {Bandit, :start_link, [bandit_options]}} = child_spec
      assert Keyword.fetch!(bandit_options, :ip) == {0, 0, 0, 0}
    end
  end

  test "http app applies custom middleware to custom routes" do
    server_name = "http-app-routes-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        unsafe_allow_any_host: true,
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
    assert JSON.decode!(response.resp_body) == %{"message" => "Hello, world!"}
  end

  test "http app middleware can modify request state for custom routes" do
    server_name = "http-app-state-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        unsafe_allow_any_host: true,
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

    assert JSON.decode!(response.resp_body) == %{
             "state" => %{"modified_by" => "middleware"}
           }
  end

  test "http app middleware also wraps MCP transport routes" do
    server_name = "http-app-mcp-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    app =
      FastestMCP.http_app(server_name,
        unsafe_allow_any_host: true,
        json_response: true,
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-transport-middleware", "applied"))
            |> next.()
          end
        ]
      )

    session_id = initialize_app(app)

    response =
      app_request(
        app,
        ProtocolTest.jsonrpc_request(2, "tools/call", %{
          "name" => "echo",
          "arguments" => %{}
        }),
        session_id
      )

    assert response.status == 200
    assert get_resp_header(response, "x-transport-middleware") == ["applied"]

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{}"}],
               "structuredContent" => %{}
             }
           } = JSON.decode!(response.resp_body)
  end

  test "http app forwards stateless streamable HTTP options to the transport" do
    server_name = "http-app-stateless-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    app =
      FastestMCP.http_app(server_name,
        stateless_http: true,
        unsafe_allow_any_host: true,
        json_response: true
      )

    get_response = conn(:get, "/mcp") |> app.()
    assert get_response.status == 405

    post_response =
      conn(
        :post,
        "/mcp",
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> app.()

    assert post_response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 9,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{\"message\":\"hi\"}"}],
               "structuredContent" => %{"message" => "hi"}
             }
           } = JSON.decode!(post_response.resp_body)
  end

  test "http app can reject non-local host and origin headers when allowed_hosts is configured" do
    server_name = "http-app-host-guard-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app = FastestMCP.http_app(server_name, allowed_hosts: :localhost)

    blocked =
      conn(
        :post,
        "/mcp",
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => ProtocolTest.initialize_params()
        })
      )
      |> Map.put(:host, "evil.example.com")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "http://evil.example.com")
      |> app.()

    assert blocked.status == 403

    allowed =
      conn(
        :post,
        "/mcp",
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => ProtocolTest.initialize_params()
        })
      )
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "http://127.0.0.1:4000")
      |> app.()

    assert allowed.status == 200
  end

  test "http app applies multiple middleware in order" do
    server_name = "http-app-order-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        unsafe_allow_any_host: true,
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
    |> send_resp(status, JSON.encode!(payload))
  end

  defp initialize_app(app) do
    initialize_response =
      app_request(
        app,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      )

    assert initialize_response.status == 200
    [session_id] = get_resp_header(initialize_response, "mcp-session-id")

    initialized_response =
      app_request(
        app,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized_response.status == 202
    session_id
  end

  defp app_request(app, payload, session_id \\ nil) do
    conn(:post, "/mcp", JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> maybe_put_session_headers(session_id)
    |> app.()
  end

  defp maybe_put_session_headers(conn, nil), do: conn

  defp maybe_put_session_headers(conn, session_id) do
    conn
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
  end
end
