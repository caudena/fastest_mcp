defmodule FastestMCP.P0TransportFoundationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Registry
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StdioAdapter
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

  test "the shared codec preserves usable ids, rejects scalar results, and silences malformed notifications" do
    assert {:error, %Error{jsonrpc_id: 7}} =
             JSONRPC.decode(%{"jsonrpc" => "2.0", "id" => 7, "method" => 123})

    assert {:error, %Error{code: :invalid_request}} =
             JSONRPC.decode(%{"jsonrpc" => "2.0", "id" => 8, "result" => "not-an-object"})

    malformed_notification = %{"jsonrpc" => "2.0", "method" => 123}
    assert {:error, %Error{jsonrpc_notification: true}} = JSONRPC.decode(malformed_notification)

    server_name = unique_server_name("codec-notification")
    start_server!(FastestMCP.server(server_name))

    assert :no_response = Stdio.dispatch(server_name, malformed_notification)

    error_payload =
      Stdio.dispatch(server_name, %{"jsonrpc" => "2.0", "id" => "known", "method" => 123})

    assert %{"id" => "known", "error" => %{"code" => -32_600}} = error_payload

    parse_payload = Stdio.dispatch(server_name, "{invalid-json")
    assert %{"error" => %{"code" => -32_700}} = parse_payload
    refute Map.has_key?(parse_payload, "id")

    idless_error = %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32_600, "message" => "request id was unreadable"}
    }

    assert {:ok, {:response, nil, ^idless_error}} =
             JSONRPC.decode(idless_error, direction: :server_to_client)

    assert {:error, %Error{code: :invalid_request}} =
             JSONRPC.decode(Map.put(idless_error, "id", nil), direction: :server_to_client)

    assert {:ok, {:request, "", %{}, 9}} =
             JSONRPC.decode(%{"jsonrpc" => "2.0", "id" => 9, "method" => ""})
  end

  test "unsupported task augmentation is ignored before adapter dispatch" do
    assert {:ok, {:request, "ping", %{}, 1}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "ping",
               "params" => %{"task" => true}
             })

    assert {:ok, {:request, "roots/list", %{}, 2}} =
             JSONRPC.decode(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 2,
                 "method" => "roots/list",
                 "params" => %{"task" => -1}
               },
               direction: :server_to_client
             )

    assert {:error, %Error{code: :invalid_params}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "tools/call",
               "params" => %{"name" => "echo", "task" => true}
             })
  end

  test "unsupported versions negotiate 2025-11-25 and initialized must be a notification" do
    server_name = unique_server_name("version-negotiation")
    start_server!(FastestMCP.server(server_name))

    unsupported = %{"protocolVersion" => "2025-03-26"}

    {session_id, initialize_response} =
      ProtocolTest.http_initialize(server_name, [], unsupported)

    assert initialize_response.status == 200

    assert %{
             "result" => %{"protocolVersion" => negotiated_version}
           } = JSON.decode!(initialize_response.resp_body)

    assert negotiated_version == ProtocolTest.protocol_version()

    id_bearing_initialized =
      ProtocolTest.http_request(server_name, session_id, 2, "notifications/initialized")

    assert id_bearing_initialized.status == 200

    assert %{
             "id" => 2,
             "error" => %{
               "code" => -32_600,
               "message" =>
                 "MCP method notifications/initialized must be a notification, not a request"
             }
           } = JSON.decode!(id_bearing_initialized.resp_body)

    assert {:ok, %{state: :initializing}} = Session.lifecycle(server_name, session_id)
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202
    assert {:ok, %{state: :initialized}} = Session.lifecycle(server_name, session_id)

    connection_id = {:unsupported_version, make_ref()}

    stdio_initialize =
      Stdio.dispatch(
        server_name,
        ProtocolTest.jsonrpc_request(
          1,
          "initialize",
          ProtocolTest.initialize_params(unsupported)
        ),
        connection_id: connection_id
      )

    assert %{"result" => %{"protocolVersion" => ^negotiated_version}} = stdio_initialize

    assert %{"error" => %{"code" => -32_600}} =
             ProtocolTest.stdio_request(
               server_name,
               connection_id,
               2,
               "notifications/initialized"
             )

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("notifications/initialized"),
               connection_id: connection_id
             )
  end

  test "HTTP authentication covers lifecycle and control requests and binds a session identity" do
    server_name = unique_server_name("transport-auth")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(HeaderAuth)

    start_server!(server)

    {_unusable_session_id, unauthorized_initialize} =
      initialize_without_requiring_session_header(server_name, [])

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

  test "direct mounts enforce Host and Origin and reject the removed unsafe mode" do
    server_name = unique_server_name("direct-host-origin")
    start_server!(FastestMCP.server(server_name))
    payload = ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())

    hostile_host = initialize_conn(payload) |> Map.put(:host, "evil.example")
    assert StreamableHTTP.call(hostile_host, server_name: server_name).status == 403

    hostile_origin =
      payload
      |> initialize_conn()
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
      payload
      |> initialize_conn()
      |> localhost()
      |> StreamableHTTP.call(server_name: server_name)

    assert allowed_response.status == 200
  end

  test "JSON-RPC application errors stay on HTTP 200 and do not invalidate the session" do
    server_name = unique_server_name("application-status")
    start_server!(FastestMCP.server(server_name))
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

  test "reused request ids are accepted with a warning by default within one HTTP or stdio session" do
    server_name = unique_server_name("request-id-lenient")
    start_server!(FastestMCP.server(server_name))
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    assert ProtocolTest.http_request(server_name, session_id, 2, "ping").status == 200

    # claude.ai restarts its JSON-RPC id numbering inside a live session after
    # resuming a conversation and treats a rejection as a tool failure without
    # re-initializing, so a reused id must still be served.
    {reused, log} =
      with_log(fn -> ProtocolTest.http_request(server_name, session_id, 2, "ping") end)

    assert reused.status == 200
    assert %{"id" => 2, "result" => %{}} = JSON.decode!(reused.resp_body)
    assert log =~ "[warning]"
    assert log =~ "reused JSON-RPC request id"
    assert log =~ "request_id=2"
    assert log =~ "session_id=#{inspect(session_id)}"
    assert log =~ ~s(method="ping")

    # The session keeps serving fresh ids after a reuse.
    assert %{"result" => %{}} =
             JSON.decode!(ProtocolTest.http_request(server_name, session_id, 3, "ping").resp_body)

    {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name)
    assert %{"result" => %{}} = ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")

    {stdio_reused, stdio_log} =
      with_log(fn -> ProtocolTest.stdio_request(server_name, connection_id, 2, "ping") end)

    assert %{"id" => 2, "result" => %{}} = stdio_reused
    assert stdio_log =~ "reused JSON-RPC request id"
    assert stdio_log =~ "request_id=2"
  end

  test "strict_request_ids: true rejects reused request ids within one HTTP or stdio session" do
    server_name = unique_server_name("request-id-ledger")
    start_server!(FastestMCP.server(server_name), strict_request_ids: true)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    assert ProtocolTest.http_request(server_name, session_id, 2, "ping").status == 200

    {reused, log} =
      with_log(fn -> ProtocolTest.http_request(server_name, session_id, 2, "ping") end)

    assert reused.status == 200

    assert %{"id" => 2, "error" => %{"code" => -32_600, "message" => message}} =
             JSON.decode!(reused.resp_body)

    assert message =~ "already been used"
    refute log =~ "reused JSON-RPC request id"

    distinct_string = ProtocolTest.http_request(server_name, session_id, "2", "ping")
    assert distinct_string.status == 200
    assert %{"result" => %{}} = JSON.decode!(distinct_string.resp_body)

    {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name)
    assert %{"result" => %{}} = ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")

    assert %{"error" => %{"code" => -32_600}} =
             ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")
  end

  test "strict_request_ids must be a boolean" do
    server_name = unique_server_name("request-id-policy-invalid")

    assert {:error, %ArgumentError{message: message}} =
             FastestMCP.start_server(FastestMCP.server(server_name), strict_request_ids: "yes")

    assert message =~ "strict_request_ids must be a boolean"
  end

  test "request id exhaustion returns one bounded correlated error before terminating HTTP and stdio sessions" do
    server_name = unique_server_name("request-id-capacity")
    start_server!(FastestMCP.server(server_name), max_request_ids: 2)

    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert ProtocolTest.http_request(server_name, session_id, 2, "ping").status == 200

    exhausted = ProtocolTest.http_request(server_name, session_id, 3, "ping")
    assert exhausted.status == 200

    assert %{
             "id" => 3,
             "error" => %{
               "code" => -32_002,
               "data" => %{
                 "fastestmcp" => %{
                   "code" => "overloaded",
                   "details" => %{
                     "resource" => "request_ids",
                     "retry_after_seconds" => 1
                   }
                 }
               }
             }
           } = JSON.decode!(exhausted.resp_body)

    assert byte_size(exhausted.resp_body) < 1_024
    assert {:error, :not_found} = Registry.lookup_session(server_name, session_id)
    assert ProtocolTest.http_request(server_name, session_id, 4, "ping").status == 404

    {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name)
    assert %{"result" => %{}} = ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")

    stdio_exhausted = ProtocolTest.stdio_request(server_name, connection_id, 3, "ping")

    assert %{
             "id" => 3,
             "error" => %{
               "code" => -32_002,
               "data" => %{"fastestmcp" => %{"code" => "overloaded"}}
             }
           } = stdio_exhausted

    assert stdio_exhausted |> JSON.encode!() |> byte_size() < 1_024

    assert {:error, :not_found} =
             Registry.lookup_session(
               server_name,
               StdioAdapter.connection_session_id(connection_id)
             )
  end

  test "request id exhaustion is delivered as an SSE terminal error before session teardown" do
    server_name = unique_server_name("request-id-sse-capacity")
    start_server!(FastestMCP.server(server_name), max_request_ids: 2)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    assert ProtocolTest.http_request(server_name, session_id, 2, "ping").status == 200

    exhausted =
      ProtocolTest.http_request(
        server_name,
        session_id,
        3,
        "ping",
        %{},
        json_response: false
      )

    assert exhausted.status == 200
    assert exhausted.state == :chunked
    assert Plug.Conn.get_resp_header(exhausted, "content-type") == ["text/event-stream"]

    assert %{
             "id" => 3,
             "error" => %{
               "code" => -32_002,
               "data" => %{"fastestmcp" => %{"code" => "overloaded"}}
             }
           } = streamed_jsonrpc_message(exhausted.resp_body)

    assert {:error, :not_found} = Registry.lookup_session(server_name, session_id)
  end

  test "request-local state keeps the negotiated HTTP session identity" do
    server_name = unique_server_name("request-state")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("state", fn _arguments, context ->
        count = Context.get_state(context, :count, 0)
        :ok = Context.set_state(context, :count, count + 1)
        %{count: count + 1, session_id: context.session_id, state_scope: context.state_scope}
      end)

    start_server!(server)
    call_opts = [state_scope: :request]

    {session_id, _initialize, initialized} =
      ProtocolTest.initialize_http(server_name, call_opts)

    assert initialized.status == 202

    for id <- [2, 3] do
      response =
        ProtocolTest.http_request(
          server_name,
          session_id,
          id,
          "tools/call",
          %{"name" => "state"},
          call_opts
        )

      assert response.status == 200

      assert %{
               "result" => %{
                 "structuredContent" => %{
                   "count" => 1,
                   "session_id" => ^session_id,
                   "state_scope" => "request"
                 }
               }
             } = JSON.decode!(response.resp_body)
    end
  end

  defp initialize_without_requiring_session_header(server_name, headers) do
    response =
      ProtocolTest.http_post(
        server_name,
        nil,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params()),
        headers: headers
      )

    {get_resp_header(response, "mcp-session-id") |> List.first(), response}
  end

  defp initialize_conn(payload) do
    conn(:post, "/mcp", JSON.encode!(payload))
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

  defp streamed_jsonrpc_message(body) do
    Enum.find_value(String.split(body, "\n"), fn
      "data: " <> json when json != "" -> JSON.decode!(json)
      _line -> nil
    end)
  end

  defp start_server!(server, opts \\ []) do
    assert {:ok, _pid} = FastestMCP.start_server(server, opts)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_server_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
