defmodule FastestMCP.JSONRPCTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FastestMCP.Error
  alias FastestMCP.Registry
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StdioAdapter

  setup do
    server_name = unique_name("jsonrpc")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end, task: true)
      |> FastestMCP.add_resource("existing://resource", fn _arguments, _ctx -> "ok" end)
      |> FastestMCP.add_prompt("existing-prompt", fn _arguments, _ctx -> "ok" end)
    )

    %{server_name: server_name}
  end

  test "task augmentation uses top-level params.task and validates its shape" do
    assert {:ok, {true, 30_000}} = JSONRPC.task_metadata(%{"task" => %{"ttl" => 30_000}})
    assert {:ok, {true, nil}} = JSONRPC.task_metadata(%{"task" => %{}})

    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"task" => %{"ttl" => 30_000}}})

    assert {:error, %Error{code: :invalid_params, message: "task must be an object"}} =
             JSONRPC.task_metadata(%{"task" => true})

    assert {:error,
            %Error{
              code: :invalid_params,
              message: "task.ttl must be a positive integer"
            }} = JSONRPC.task_metadata(%{"task" => %{"ttl" => 0}})
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

  test "request metadata accepts only string or integer progress tokens" do
    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => "progress-1"}})

    assert {:ok, {false, nil}} =
             JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => 42}})

    for invalid <- [nil, false, 1.5, %{}, []] do
      assert {:error,
              %Error{
                code: :invalid_params,
                message: "params._meta.progressToken must be a string or integer"
              }} = JSONRPC.task_metadata(%{"_meta" => %{"progressToken" => invalid}})
    end

    assert {:error, %Error{code: :invalid_params}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => "progress-request",
               "method" => "ping",
               "params" => %{"_meta" => %{"progressToken" => false}}
             })
  end

  test "the shared codec preserves usable ids, rejects scalar results, and silences malformed notifications",
       %{server_name: server_name} do
    assert {:error, %Error{jsonrpc_id: 7}} =
             JSONRPC.decode(%{"jsonrpc" => "2.0", "id" => 7, "method" => 123})

    assert {:error, %Error{code: :invalid_request}} =
             JSONRPC.decode(%{"jsonrpc" => "2.0", "id" => 8, "result" => "not-an-object"})

    malformed_notification = %{"jsonrpc" => "2.0", "method" => 123}
    assert {:error, %Error{jsonrpc_notification: true}} = JSONRPC.decode(malformed_notification)

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

    connection_id = {:jsonrpc_stdio, make_ref()}

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

    modern_missing =
      ProtocolTest.modern_http_request(server_name, 9, "missing/method")

    assert modern_missing.status == 404
    assert_jsonrpc_error(JSON.decode!(modern_missing.resp_body), -32_601, "method_not_found")
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
    server_name = unique_name("notification-auth")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn _input, _context ->
      {:error, %Error{code: :unauthorized, message: "authentication required"}}
    end)
    |> start_server!()

    ProtocolTest.initialize_session(server_name, "notification-auth-session")

    response =
      ProtocolTest.http_post(
        server_name,
        "notification-auth-session",
        ProtocolTest.jsonrpc_notification("tools/list")
      )

    assert response.status == 401
    assert response.resp_body == ""
    assert Plug.Conn.get_resp_header(response, "www-authenticate") == ["Bearer"]
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
      ProtocolTest.http_post_raw(
        server_name,
        JSON.encode!(%{"jsonrpc" => "2.0", "method" => 123})
      )

    assert malformed_http_notification.status == 400
    assert malformed_http_notification.resp_body == ""

    http_parse_error = ProtocolTest.http_post_raw(server_name, "{not-json")
    assert http_parse_error.status == 400

    http_parse_error_body = JSON.decode!(http_parse_error.resp_body)
    assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32_700}} = http_parse_error_body
    refute Map.has_key?(http_parse_error_body, "id")

    http_invalid_request = ProtocolTest.http_post_raw(server_name, JSON.encode!(invalid_message))

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

  test "reused request ids are accepted with a warning by default within one HTTP or stdio session",
       %{server_name: server_name} do
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
    server_name = unique_name("request-id-ledger")
    start_server!(FastestMCP.server(server_name), strict_request_ids: true)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    assert ProtocolTest.http_request(server_name, session_id, 2, "ping").status == 200

    {reused, log} =
      with_log(fn -> ProtocolTest.http_request(server_name, session_id, 2, "ping") end)

    assert reused.status == 200

    assert %{"id" => 2, "error" => %{"code" => -32_600, "message" => message}} =
             JSON.decode!(reused.resp_body)

    assert message =~ "already been used"
    refute log =~ "reused JSON-RPC request id: request_id=2; session_id=#{inspect(session_id)}"

    distinct_string = ProtocolTest.http_request(server_name, session_id, "2", "ping")
    assert distinct_string.status == 200
    assert %{"result" => %{}} = JSON.decode!(distinct_string.resp_body)

    {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name)
    assert %{"result" => %{}} = ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")

    assert %{"error" => %{"code" => -32_600}} =
             ProtocolTest.stdio_request(server_name, connection_id, 2, "ping")
  end

  test "strict_request_ids must be a boolean" do
    server_name = unique_name("request-id-policy-invalid")

    assert_raise ArgumentError, ~r/strict_request_ids must be a boolean/, fn ->
      FastestMCP.start_server(FastestMCP.server(server_name), strict_request_ids: "yes")
    end
  end

  test "request id exhaustion returns one bounded correlated error before terminating HTTP and stdio sessions" do
    server_name = unique_name("request-id-capacity")
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
    server_name = unique_name("request-id-sse-capacity")
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
           } = ProtocolTest.sse_message(exhausted.resp_body)

    assert {:error, :not_found} = Registry.lookup_session(server_name, session_id)
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
