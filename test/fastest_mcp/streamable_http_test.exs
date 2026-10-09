defmodule FastestMCP.StreamableHTTPTest do
  use FastestMCP.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error
  alias FastestMCP.Session
  alias FastestMCP.Transport.StreamableHTTP

  defmodule HeaderAuth do
    @behaviour FastestMCP.Auth

    @impl true
    def authenticate(%{"authorization" => "Bearer " <> identity}, _context, _opts) do
      {:ok,
       %FastestMCP.Auth.Result{
         principal: %{"sub" => identity},
         auth: %{client_id: identity},
         capabilities: []
       }}
    end

    def authenticate(_input, _context, _opts) do
      {:error, %Error{code: :unauthorized, message: "authentication required"}}
    end
  end

  setup do
    server_name = unique_name("http-endpoint")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    )

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
      |> localhost()
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
      initialize_request()
      |> post_conn("/mcp?session_id=spoofed-session")
      |> localhost()
      |> StreamableHTTP.call(server_name: server_name)

    assert initialize_response.status == 200
    [session_id] = get_resp_header(initialize_response, "mcp-session-id")
    refute session_id == "spoofed-session"
    assert session_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/

    delete_response =
      conn(:delete, "/mcp?session_id=#{session_id}")
      |> localhost()
      |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
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
      ProtocolTest.http_post_raw(
        server_name,
        JSON.encode!([
          initialize_request(),
          ProtocolTest.jsonrpc_notification("notifications/initialized")
        ]),
        transport_opts: []
      )

    assert response.status == 400
    assert get_resp_header(response, "mcp-session-id") == []

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

  test "DELETE /mcp terminates a session and rejects later reuse", %{server_name: server_name} do
    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    delete_response =
      conn(:delete, "/mcp")
      |> localhost()
      |> put_session_headers(session_id)
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

  test "GET /mcp requires event-stream negotiation and an existing session", %{
    server_name: server_name
  } do
    missing_accept =
      conn(:get, "/mcp")
      |> localhost()
      |> StreamableHTTP.call(server_name: server_name)

    assert missing_accept.status == 406

    assert %{
             "error" => %{
               "message" => "MCP GET requires text/event-stream"
             }
           } = JSON.decode!(missing_accept.resp_body)

    unacceptable =
      conn(:get, "/mcp")
      |> localhost()
      |> put_req_header("accept", "text/event-stream;q=0")
      |> StreamableHTTP.call(server_name: server_name)

    assert unacceptable.status == 406

    unknown_session =
      conn(:get, "/mcp")
      |> localhost()
      |> put_req_header("accept", "text/event-stream")
      |> put_session_headers("client-invented-session")
      |> StreamableHTTP.call(server_name: server_name)

    assert unknown_session.status == 404

    body = JSON.decode!(unknown_session.resp_body)
    assert %{"jsonrpc" => "2.0", "error" => %{"message" => message}} = body
    refute Map.has_key?(body, "id")

    assert message =~ "unknown session"
  end

  test "GET /mcp returns 405 when session streaming is explicitly disabled", %{
    server_name: server_name
  } do
    response =
      conn(:get, "/mcp")
      |> localhost()
      |> put_req_header("accept", "text/event-stream")
      |> StreamableHTTP.call(server_name: server_name, enable_get_streaming: false)

    assert response.status == 405
    assert get_resp_header(response, "allow") == ["POST, DELETE"]

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

  test "production HTTP rejects protocol versions other than 2025-11-25", %{
    server_name: server_name
  } do
    {session_id, _initialize_response} = ProtocolTest.http_initialize(server_name)

    response =
      ProtocolTest.http_post_raw(
        server_name,
        JSON.encode!(ProtocolTest.jsonrpc_request(2, "ping")),
        session_id: session_id,
        protocol_version: "2025-03-26"
      )

    assert response.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{"code" => -32_602, "message" => message}
           } = JSON.decode!(response.resp_body)

    assert message =~ "unsupported MCP-Protocol-Version"
  end

  test "HTTP validates exact media types and handles them case-insensitively", %{
    server_name: server_name
  } do
    initialize = JSON.encode!(initialize_request())
    post_initialize = &ProtocolTest.http_post_raw(server_name, initialize, &1)

    assert post_initialize.(content_type: nil).status == 415
    assert post_initialize.(content_type: "application/jsonx").status == 415

    duplicate_content_type =
      :post
      |> conn("/mcp", initialize)
      |> localhost()
      |> put_req_header("content-type", "application/json")
      |> prepend_req_headers([{"content-type", "text/plain"}])
      |> put_req_header("accept", "application/json, text/event-stream")
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

    assert duplicate_content_type.status == 415

    assert post_initialize.(accept: nil).status == 406

    wildcard = post_initialize.(accept: "*/*")
    assert wildcard.status == 200

    assert post_initialize.(accept: "application/*, text/*").status == 200
    assert post_initialize.(accept: "application/*").status == 406
    assert post_initialize.(accept: "application/json;q=0, text/event-stream").status == 406
    assert post_initialize.(accept: "*/*;q=1, application/json;q=0").status == 406

    initialized =
      post_initialize.(
        content_type: "Application/JSON; charset=UTF-8",
        accept: "APPLICATION/JSON; q=1, TEXT/EVENT-STREAM"
      )

    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    streamed =
      ProtocolTest.http_post_raw(
        server_name,
        JSON.encode!(
          ProtocolTest.jsonrpc_request(2, "tools/call", %{
            "name" => "echo",
            "arguments" => %{"value" => 42}
          })
        ),
        accept: "APPLICATION/JSON, TEXT/EVENT-STREAM",
        session_id: session_id,
        transport_opts: []
      )

    assert streamed.status == 200
    assert get_resp_header(streamed, "content-type") == ["text/event-stream"]
  end

  test "legacy stateless HTTP options fail fast", %{server_name: server_name} do
    for option <- [:stateless_http, :stateless] do
      assert_raise ArgumentError,
                   "stateless HTTP is no longer supported; use state_scope: :request for request-local handler state",
                   fn ->
                     ProtocolTest.http_post_raw(
                       server_name,
                       JSON.encode!(initialize_request()),
                       transport_opts: [{option, true}, {:json_response, true}]
                     )
                   end
    end

    assert registered_sessions(server_name) == 0
  end

  test "HTTP authentication covers lifecycle and control requests and binds a session identity" do
    server_name = unique_name("transport-auth")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(HeaderAuth)

    start_server!(server)

    unauthorized_initialize = ProtocolTest.http_post(server_name, nil, initialize_request())

    assert unauthorized_initialize.status == 401
    assert get_resp_header(unauthorized_initialize, "mcp-session-id") == []
    assert ["Bearer " <> _rest] = get_resp_header(unauthorized_initialize, "www-authenticate")

    {session_id, initialize_response} =
      ProtocolTest.http_initialize(server_name, headers: authorization("alice"))

    assert initialize_response.status == 200

    missing_initialized = ProtocolTest.http_mark_initialized(server_name, session_id)
    assert missing_initialized.status == 401
    assert missing_initialized.resp_body == ""
    assert {:ok, %{state: :initializing}} = Session.lifecycle(server_name, session_id)

    assert ProtocolTest.http_mark_initialized(
             server_name,
             session_id,
             headers: authorization("alice")
           ).status == 202

    cross_principal =
      ProtocolTest.http_request(server_name, session_id, 2, "ping", %{},
        headers: authorization("bob")
      )

    assert cross_principal.status == 403

    missing_ping = ProtocolTest.http_request(server_name, session_id, 3, "ping")
    assert missing_ping.status == 401

    missing_get =
      :get
      |> conn("/mcp")
      |> localhost()
      |> put_req_header("accept", "text/event-stream")
      |> put_session_headers(session_id)
      |> StreamableHTTP.call(server_name: server_name)

    assert missing_get.status == 401

    wrong_delete =
      :delete
      |> conn("/mcp")
      |> localhost()
      |> put_session_headers(session_id)
      |> put_req_header("authorization", "Bearer bob")
      |> StreamableHTTP.call(server_name: server_name)

    assert wrong_delete.status == 403

    missing_client_response =
      ProtocolTest.http_post(
        server_name,
        session_id,
        %{"jsonrpc" => "2.0", "id" => "server-request", "result" => %{}}
      )

    assert missing_client_response.status == 401

    valid_ping =
      ProtocolTest.http_request(server_name, session_id, 4, "ping", %{},
        headers: authorization("alice")
      )

    assert valid_ping.status == 200

    valid_delete =
      :delete
      |> conn("/mcp")
      |> localhost()
      |> put_session_headers(session_id)
      |> put_req_header("authorization", "Bearer alice")
      |> StreamableHTTP.call(server_name: server_name)

    assert valid_delete.status == 204
  end

  test "direct mounts enforce Host and Origin and reject the removed unsafe mode", %{
    server_name: server_name
  } do
    hostile_host = initialize_request() |> post_conn() |> Map.put(:host, "evil.example")
    assert StreamableHTTP.call(hostile_host, server_name: server_name).status == 403

    hostile_origin =
      initialize_request()
      |> post_conn()
      |> localhost()
      |> put_req_header("origin", "https://evil.example")

    assert StreamableHTTP.call(hostile_origin, server_name: server_name).status == 403

    assert_raise ArgumentError, ~r/unsafe_allow_any_host is no longer supported/, fn ->
      StreamableHTTP.call(hostile_host,
        server_name: server_name,
        unsafe_allow_any_host: true
      )
    end

    allowed_response =
      initialize_request()
      |> post_conn()
      |> localhost()
      |> StreamableHTTP.call(server_name: server_name)

    assert allowed_response.status == 200
  end

  test "JSON-RPC application errors stay on HTTP 200 and do not invalidate the session", %{
    server_name: server_name
  } do
    {session_id, _initialize, initialized} = ProtocolTest.initialize_http(server_name)
    assert initialized.status == 202

    unknown_method = ProtocolTest.http_request(server_name, session_id, 2, "missing/method")
    assert unknown_method.status == 200
    assert %{"error" => %{"code" => -32_601}} = JSON.decode!(unknown_method.resp_body)

    invalid_params = ProtocolTest.http_request(server_name, session_id, 3, "tools/call")
    assert invalid_params.status == 200
    assert %{"error" => %{"code" => -32_602}} = JSON.decode!(invalid_params.resp_body)

    assert ProtocolTest.http_request(server_name, session_id, 4, "ping").status == 200
  end

  defp initialize_request,
    do: ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())

  defp post_conn(payload, path \\ "/mcp") do
    conn(:post, path, JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp localhost(conn), do: Map.put(conn, :host, "localhost")

  defp put_session_headers(conn, session_id) do
    conn
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
  end

  defp authorization(identity), do: [{"authorization", "Bearer " <> identity}]
end
