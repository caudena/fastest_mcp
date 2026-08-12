defmodule FastestMCP.ProtocolMatrixTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Registry
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP

  setup do
    server_name = "protocol-matrix-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("existing://resource", fn _arguments, _ctx -> "ok" end)
      |> FastestMCP.add_prompt("existing-prompt", fn _arguments, _ctx -> "ok" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    %{server_name: server_name}
  end

  test "task augmentation uses top-level params.task and validates its shape" do
    assert {:ok, {true, 30_000}} = JSONRPC.task_metadata(%{"task" => %{"ttl" => 30_000}})
    assert {:ok, {true, nil}} = JSONRPC.task_metadata(%{"task" => %{}})

    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"task" => %{"ttl" => 30_000}}})

    assert {:error, %FastestMCP.Error{code: :invalid_params, message: "task must be an object"}} =
             JSONRPC.task_metadata(%{"task" => true})

    assert {:error,
            %FastestMCP.Error{
              code: :invalid_params,
              message: "task.ttl must be a positive integer"
            }} = JSONRPC.task_metadata(%{"task" => %{"ttl" => 0}})
  end

  test "request metadata accepts only string or integer progress tokens" do
    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => "progress-1"}})

    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => 42}})

    for invalid <- [nil, false, 1.5, %{}, []] do
      assert {:error,
              %FastestMCP.Error{
                code: :invalid_params,
                message: "params._meta.progressToken must be a string or integer"
              }} = JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => invalid}})
    end

    assert {:error, %FastestMCP.Error{code: :invalid_params}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => "progress-request",
               "method" => "ping",
               "params" => %{"_meta" => %{"progressToken" => false}}
             })
  end

  test "HTTP and stdio allow ping while initializing but reject ordinary requests", %{
    server_name: server_name
  } do
    {session_id, initialize_response} = ProtocolTest.http_initialize(server_name)
    assert initialize_response.status == 200

    http_ping = ProtocolTest.http_request(server_name, session_id, 2, "ping")
    assert http_ping.status == 200
    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}} = JSON.decode!(http_ping.resp_body)

    http_tools = ProtocolTest.http_request(server_name, session_id, 3, "tools/list")
    assert http_tools.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "error" => %{
               "code" => -32_600,
               "message" => "session is not initialized"
             }
           } = JSON.decode!(http_tools.resp_body)

    connection_id = {:matrix_stdio, make_ref()}

    stdio_initialize =
      Stdio.dispatch(
        server_name,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params()),
        connection_id: connection_id
      )

    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}} = stdio_initialize

    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}} =
             ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "error" => %{
               "code" => -32_600,
               "message" => "session is not initialized"
             }
           } = ProtocolTest.stdio_request(server_name, connection_id, 3, "tools/list")
  end

  test "unknown methods and missing identifiers use distinct JSON-RPC codes", %{
    server_name: server_name
  } do
    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(server_name)

    assert_jsonrpc_error(
      ProtocolTest.stdio_request(server_name, connection_id, 2, "missing/method"),
      -32_601,
      "method_not_found"
    )

    for {id, method, params, standard_code, symbolic_code} <- [
          {3, "tools/call", %{"name" => "missing-tool"}, -32_602, "not_found"},
          {4, "resources/read", %{"uri" => "missing://resource"}, -32_002, "not_found"},
          {5, "prompts/get", %{"name" => "missing-prompt"}, -32_602, "not_found"},
          {6, "tasks/get", %{"taskId" => "missing-task"}, -32_602, "invalid_task_id"}
        ] do
      assert_jsonrpc_error(
        ProtocolTest.stdio_request(server_name, connection_id, id, method, params),
        standard_code,
        symbolic_code
      )
    end

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    method_response =
      ProtocolTest.http_request(server_name, session_id, 7, "missing/method")

    assert method_response.status == 200

    assert_jsonrpc_error(
      JSON.decode!(method_response.resp_body),
      -32_601,
      "method_not_found"
    )

    tool_response =
      ProtocolTest.http_request(server_name, session_id, 8, "tools/call", %{
        "name" => "missing-tool"
      })

    assert tool_response.status == 200
    assert_jsonrpc_error(JSON.decode!(tool_response.resp_body), -32_602, "not_found")
  end

  test "rejected notifications use empty HTTP errors while stdio remains silent", %{
    server_name: server_name
  } do
    before_initialize = ProtocolTest.jsonrpc_notification("tools/list")

    http_before_initialize =
      ProtocolTest.http_post(server_name, nil, before_initialize)

    assert http_before_initialize.status == 400
    assert http_before_initialize.resp_body == ""

    connection_id = {:notification_stdio, make_ref()}

    assert :no_response =
             Stdio.dispatch(server_name, before_initialize, connection_id: connection_id)

    {session_id, _initialize_response} = ProtocolTest.http_initialize(server_name)

    http_during_initialization =
      ProtocolTest.http_post(server_name, session_id, before_initialize)

    assert http_during_initialization.status == 400
    assert http_during_initialization.resp_body == ""
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    missing_method_notification =
      ProtocolTest.http_post(
        server_name,
        session_id,
        ProtocolTest.jsonrpc_notification("missing/method")
      )

    assert missing_method_notification.status == 202
    assert missing_method_notification.resp_body == ""

    invalid_handler_notification =
      ProtocolTest.http_post(
        server_name,
        session_id,
        ProtocolTest.jsonrpc_notification("logging/setLevel", %{"level" => "verbose"})
      )

    assert invalid_handler_notification.status == 202
    assert invalid_handler_notification.resp_body == ""

    accepted_notification =
      ProtocolTest.http_post(
        server_name,
        session_id,
        ProtocolTest.jsonrpc_notification("logging/setLevel", %{"level" => "info"})
      )

    assert accepted_notification.status == 202
    assert accepted_notification.resp_body == ""

    stdio_initialize =
      Stdio.dispatch(
        server_name,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params()),
        connection_id: connection_id
      )

    assert %{"result" => %{}} = stdio_initialize

    assert :no_response =
             Stdio.dispatch(server_name, before_initialize, connection_id: connection_id)

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("notifications/initialized"),
               connection_id: connection_id
             )

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("missing/method"),
               connection_id: connection_id
             )

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("logging/setLevel", %{"level" => "verbose"}),
               connection_id: connection_id
             )
  end

  test "rejected HTTP notifications preserve authentication challenge headers" do
    server_name = "notification-auth-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn _input, _context ->
        {:error, %FastestMCP.Error{code: :unauthorized, message: "authentication required"}}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    ProtocolTest.initialize_session(server_name, "notification-auth-session")

    response =
      ProtocolTest.http_post(
        server_name,
        "notification-auth-session",
        ProtocolTest.jsonrpc_notification("tools/list")
      )

    assert response.status == 401
    assert response.resp_body == ""
    assert [challenge] = Plug.Conn.get_resp_header(response, "www-authenticate")
    assert String.starts_with?(challenge, "Bearer ")
  end

  test "malformed messages still return parse and invalid-request errors", %{
    server_name: server_name
  } do
    stdio_parse_error = Stdio.dispatch(server_name, "{not-json")
    assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32_700}} = stdio_parse_error
    refute Map.has_key?(stdio_parse_error, "id")

    invalid_message = %{"jsonrpc" => "2.0", "id" => 5, "method" => 123}
    stdio_invalid_request = Stdio.dispatch(server_name, invalid_message)

    assert %{"jsonrpc" => "2.0", "id" => 5, "error" => %{"code" => -32_600}} =
             stdio_invalid_request

    assert :no_response = Stdio.dispatch(server_name, %{"jsonrpc" => "2.0", "method" => 123})

    malformed_http_notification =
      raw_http_post(server_name, JSON.encode!(%{"jsonrpc" => "2.0", "method" => 123}))

    assert malformed_http_notification.status == 400
    assert malformed_http_notification.resp_body == ""

    http_parse_error = raw_http_post(server_name, "{not-json")
    assert http_parse_error.status == 400

    http_parse_error_body = JSON.decode!(http_parse_error.resp_body)
    assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32_700}} = http_parse_error_body
    refute Map.has_key?(http_parse_error_body, "id")

    http_invalid_request =
      raw_http_post(server_name, JSON.encode!(invalid_message))

    assert http_invalid_request.status == 400

    http_invalid_request_body = JSON.decode!(http_invalid_request.resp_body)

    assert %{"jsonrpc" => "2.0", "id" => 5, "error" => %{"code" => -32_600}} =
             http_invalid_request_body
  end

  test "initialize notifications create no HTTP or stdio session", %{server_name: server_name} do
    sessions_before = registered_sessions(server_name)

    initialize_notification =
      ProtocolTest.jsonrpc_notification("initialize", ProtocolTest.initialize_params())

    http_response = ProtocolTest.http_post(server_name, nil, initialize_notification)
    assert http_response.status == 202
    assert http_response.resp_body == ""
    assert Plug.Conn.get_resp_header(http_response, "mcp-session-id") == []
    assert registered_sessions(server_name) == sessions_before

    assert :no_response =
             Stdio.dispatch(server_name, initialize_notification,
               connection_id: {:initialize_notification, make_ref()}
             )

    assert registered_sessions(server_name) == sessions_before
  end

  test "production HTTP rejects protocol versions other than 2025-11-25", %{
    server_name: server_name
  } do
    {session_id, _initialize_response} = ProtocolTest.http_initialize(server_name)

    response =
      conn(
        :post,
        "/mcp",
        JSON.encode!(ProtocolTest.jsonrpc_request(2, "ping"))
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("mcp-session-id", session_id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-03-26")
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

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
    initialize = ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())

    assert raw_http_post(server_name, JSON.encode!(initialize), content_type: nil).status == 415

    assert raw_http_post(server_name, JSON.encode!(initialize), content_type: "application/jsonx").status ==
             415

    duplicate_content_type =
      :post
      |> conn("/mcp", JSON.encode!(initialize))
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.prepend_req_headers([{"content-type", "text/plain"}])
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

    assert duplicate_content_type.status == 415

    assert raw_http_post(server_name, JSON.encode!(initialize), accept: nil).status == 406

    wildcard = raw_http_post(server_name, JSON.encode!(initialize), accept: "*/*")
    assert wildcard.status == 200

    assert raw_http_post(server_name, JSON.encode!(initialize), accept: "application/*, text/*").status ==
             200

    assert raw_http_post(server_name, JSON.encode!(initialize), accept: "application/*").status ==
             406

    assert raw_http_post(server_name, JSON.encode!(initialize),
             accept: "application/json;q=0, text/event-stream"
           ).status == 406

    assert raw_http_post(server_name, JSON.encode!(initialize),
             accept: "*/*;q=1, application/json;q=0"
           ).status == 406

    initialized =
      raw_http_post(server_name, JSON.encode!(initialize),
        content_type: "Application/JSON; charset=UTF-8",
        accept: "APPLICATION/JSON; q=1, TEXT/EVENT-STREAM"
      )

    assert initialized.status == 200
    [session_id] = Plug.Conn.get_resp_header(initialized, "mcp-session-id")
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    streamed =
      raw_http_post(
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
    assert Plug.Conn.get_resp_header(streamed, "content-type") == ["text/event-stream"]
  end

  test "legacy stateless HTTP options fail fast", %{server_name: server_name} do
    for option <- [:stateless_http, :stateless] do
      assert_raise ArgumentError,
                   "stateless HTTP is no longer supported; use state_scope: :request for request-local handler state",
                   fn ->
                     raw_http_post(
                       server_name,
                       JSON.encode!(
                         ProtocolTest.jsonrpc_request(
                           1,
                           "initialize",
                           ProtocolTest.initialize_params()
                         )
                       ),
                       transport_opts: [{option, true}, {:json_response, true}]
                     )
                   end
    end

    assert registered_sessions(server_name) == 0
  end

  test "stdio serve releases its connection session at EOF", %{server_name: server_name} do
    connection_id = {:stdio_eof, make_ref()}
    session_id = FastestMCP.Transport.StdioAdapter.connection_session_id(connection_id)

    input = [
      JSON.encode!(
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      ) <> "\n",
      JSON.encode!(ProtocolTest.jsonrpc_notification("notifications/initialized")) <> "\n"
    ]

    {:ok, output} = StringIO.open("")
    assert :ok = Stdio.serve(server_name, input, output, connection_id: connection_id)
    assert {:error, :not_found} = Registry.lookup_session(server_name, session_id)
  end

  defp raw_http_post(server_name, body, opts \\ []) do
    conn =
      conn(:post, "/mcp", body)
      |> Map.put(:host, "localhost")
      |> maybe_put_header(
        "content-type",
        Keyword.get(opts, :content_type, "application/json")
      )
      |> maybe_put_header(
        "accept",
        Keyword.get(opts, :accept, "application/json, text/event-stream")
      )
      |> maybe_put_header("mcp-session-id", Keyword.get(opts, :session_id))
      |> maybe_put_header(
        "mcp-protocol-version",
        Keyword.get(
          opts,
          :protocol_version,
          if(Keyword.get(opts, :session_id), do: ProtocolTest.protocol_version())
        )
      )

    transport_opts =
      Keyword.get(opts, :transport_opts, json_response: true)
      |> Keyword.put(:server_name, server_name)

    StreamableHTTP.call(conn, transport_opts)
  end

  defp maybe_put_header(conn, _name, nil), do: conn
  defp maybe_put_header(conn, name, value), do: Plug.Conn.put_req_header(conn, name, value)

  defp registered_sessions(server_name) do
    server_name = to_string(server_name)

    :fastest_mcp_sessions
    |> :ets.tab2list()
    |> Enum.count(fn
      {{^server_name, _session_id}, _owner} -> true
      _entry -> false
    end)
  end

  defp assert_jsonrpc_error(response, standard_code, symbolic_code) do
    assert %{
             "error" => %{
               "code" => ^standard_code,
               "data" => %{
                 "fastestmcp" => %{"code" => ^symbolic_code}
               }
             }
           } = response
  end
end
