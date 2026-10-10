defmodule FastestMCP.ServerTracingTest do
  use FastestMCP.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  alias FastestMCP.Error
  alias FastestMCP.TraceTestHelper

  setup do
    TraceTestHelper.set_exporter(self())
    _ = TraceTestHelper.drain_spans()
    :ok
  end

  test "tool calls create server spans with standard MCP attributes" do
    server_name = "trace-tool-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end)
    |> start_server!()

    assert "Hello, World!" == FastestMCP.call_tool!(server_name, "greet", %{"name" => "World"})

    spans = TraceTestHelper.drain_spans()
    span = TraceTestHelper.find_span!(spans, "tools/call greet")
    attrs = TraceTestHelper.span_attributes(span)

    assert TraceTestHelper.span_kind(span) == :server
    assert attrs["mcp.method.name"] == "tools/call"
    assert attrs["rpc.system"] == "mcp"
    assert attrs["rpc.service"] == server_name
    assert attrs["rpc.method"] == "tools/call"
    assert attrs["fastestmcp.server.name"] == server_name
    assert attrs["fastestmcp.component.type"] == "tool"
    assert attrs["fastestmcp.component.key"] == "tool:greet@"
  end

  test "resource template reads create spans keyed to the matched template" do
    server_name = "trace-resource-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_resource_template("users://{user_id}/profile", fn %{"user_id" => user_id},
                                                                        _ctx ->
      "profile for #{user_id}"
    end)
    |> start_server!()

    assert "profile for 123" == FastestMCP.read_resource!(server_name, "users://123/profile")

    spans = TraceTestHelper.drain_spans()
    span = TraceTestHelper.find_span!(spans, "resources/read")
    attrs = TraceTestHelper.span_attributes(span)

    assert TraceTestHelper.span_kind(span) == :server
    assert attrs["mcp.method.name"] == "resources/read"
    assert attrs["gen_ai.system"] == "mcp"
    assert attrs["gen_ai.operation.name"] == "resources/read"
    assert attrs["mcp.resource.uri"] == "users://123/profile"
    assert attrs["rpc.method"] == "resources/read"
    assert attrs["fastestmcp.component.type"] == "resource_template"
    assert attrs["fastestmcp.component.key"] == "template:users://{user_id}/profile@"
  end

  test "failed operations mark the span as an error" do
    server_name = "trace-error-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("explode", fn _args, _ctx -> raise "boom" end)
    |> start_server!()

    assert_raise Error, fn ->
      FastestMCP.call_tool!(server_name, "explode", %{})
    end

    spans = TraceTestHelper.drain_spans()
    span = TraceTestHelper.find_span!(spans, "tools/call explode")
    attrs = TraceTestHelper.span_attributes(span)

    assert TraceTestHelper.span_status_code(span) == :error
    assert attrs["error.type"] == "RuntimeError"
    assert attrs["fastestmcp.error.code"] == "component_crash"
  end

  test "authenticated operations include auth attributes and continue an incoming trace" do
    server_name = "trace-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{
        "valid-token" => %{client_id: "test-client-123", scopes: ["read", "write"]}
      }
    )
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    Tracer.with_span "client-request" do
      headers = FastestMCP.Telemetry.inject_trace_context()

      assert %{"value" => "ok"} ==
               FastestMCP.call_tool!(server_name, "echo", %{"value" => "ok"},
                 auth_input: %{"authorization" => "Bearer valid-token"},
                 request_metadata: headers
               )
    end

    spans = TraceTestHelper.drain_spans()
    parent_span = TraceTestHelper.find_span!(spans, "client-request")
    server_span = TraceTestHelper.find_span!(spans, "tools/call echo")
    attrs = TraceTestHelper.span_attributes(server_span)

    assert attrs["enduser.id"] == "test-client-123"
    assert attrs["enduser.scope"] == "read write"
    # An in-process call without session_id: has no session to record.
    refute Map.has_key?(attrs, "mcp.session.id")
    assert TraceTestHelper.trace_id(server_span) == TraceTestHelper.trace_id(parent_span)
    assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(parent_span)
  end

  test "a handler crash keeps its exception and stack trace for logs and spans, not clients" do
    parent = self()
    server_name = unique_name("trace-crash")

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(
      FastestMCP.Middleware.error_handling(
        include_traceback: true,
        logger: fn level, message -> send(parent, {:log, level, message}) end
      )
    )
    |> FastestMCP.add_tool("explode", fn _args, _ctx -> raise ArgumentError, "boom" end)
    |> start_server!()

    assert {:error,
            %Error{
              code: :component_crash,
              message: ~s(tool "explode" crashed: boom),
              cause: {%ArgumentError{message: "boom"}, [_ | _]}
            }} = FastestMCP.call_tool(server_name, "explode")

    # The middleware logs the handler's exception with its stack trace.
    assert_receive {:log, :error, message}
    assert message =~ "Error in tools/call: ArgumentError: boom"
    assert message =~ "test/fastest_mcp/server_tracing_test.exs"

    span =
      TraceTestHelper.drain_spans() |> TraceTestHelper.find_span!("tools/call explode")

    attrs = TraceTestHelper.span_attributes(span)
    assert attrs["error.type"] == "ArgumentError"
    assert attrs["fastestmcp.error.code"] == "component_crash"

    assert [{"exception", %{"exception.stacktrace": stacktrace}}] =
             TraceTestHelper.span_events(span)

    assert stacktrace =~ "test/fastest_mcp/server_tracing_test.exs"

    # A client receives the error without its cause.
    response =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "tools/call",
        %{"name" => "explode", "arguments" => %{}},
        headers: [{"mcp-name", "explode"}]
      )

    assert get_in(JSON.decode!(response.resp_body), ["error", "message"]) ==
             ~s(tool "explode" crashed: boom)

    refute response.resp_body =~ "server_tracing_test"
  end

  @tag :capture_log
  test "an authenticator that raised is recorded once on the current span, over HTTP too" do
    server_name = unique_name("trace-auth-crash")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn input, _ctx -> Map.fetch!(input, :user) end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    # In process, the server span of the call records it.
    assert {:error, %Error{code: :internal_error}} =
             FastestMCP.call_tool(server_name, "echo", %{}, auth_input: %{})

    # Over HTTP, no operation runs, so the span where the request arrived, such
    # as the span of HTTP instrumentation, records it.
    Tracer.with_span "POST /mcp", %{kind: :server} do
      response =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "echo"},
          headers: [{"mcp-name", "echo"}]
        )

      assert response.status == 500
    end

    spans = TraceTestHelper.drain_spans()

    for name <- ["tools/call echo", "POST /mcp"] do
      span = TraceTestHelper.find_span!(spans, name)
      attrs = TraceTestHelper.span_attributes(span)

      assert TraceTestHelper.span_status_code(span) == :error
      assert attrs["error.type"] == "KeyError"
      assert attrs["fastestmcp.error.code"] == "internal_error"

      assert [{"exception", %{"exception.stacktrace": stacktrace}}] =
               TraceTestHelper.span_events(span)

      assert stacktrace =~ "test/fastest_mcp/server_tracing_test.exs"
    end
  end

  test "an HTTP request's server span is a child of the span that receives the request" do
    server_name = unique_name("trace-http-parent")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    call = fn id, headers ->
      ProtocolTest.modern_http_request(
        server_name,
        id,
        "tools/call",
        %{"name" => "echo", "arguments" => %{}},
        headers: [{"mcp-name", "echo"} | headers]
      )
    end

    # A client sends its span in `traceparent`; HTTP instrumentation, such as
    # OpenTelemetry's for Bandit or Phoenix, continues it with a span of its own.
    Tracer.with_span "client tools/call", %{kind: :client} do
      traceparent = Map.to_list(FastestMCP.Telemetry.inject_trace_context())

      Tracer.with_span "POST /mcp", %{kind: :server} do
        assert call.(1, traceparent).status == 200
        assert call.(2, []).status == 200
      end
    end

    spans = TraceTestHelper.drain_spans()
    http_span = TraceTestHelper.find_span!(spans, "POST /mcp")
    server_spans = Enum.filter(spans, &(TraceTestHelper.span_name(&1) == "tools/call echo"))

    assert length(server_spans) == 2

    for server_span <- server_spans do
      assert TraceTestHelper.trace_id(server_span) == TraceTestHelper.trace_id(http_span)
      assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(http_span)
    end

    # A `traceparent` in `_meta` that names another trace wins.
    meta =
      Tracer.with_span "other client", %{kind: :client} do
        FastestMCP.Telemetry.inject_mcp_trace_context(%{})
      end

    Tracer.with_span "POST /mcp again", %{kind: :server} do
      ProtocolTest.modern_http_request(
        server_name,
        3,
        "tools/call",
        %{"name" => "echo", "arguments" => %{}, "_meta" => meta},
        headers: [{"mcp-name", "echo"}]
      )
    end

    spans = TraceTestHelper.drain_spans()
    other_client = TraceTestHelper.find_span!(spans, "other client")
    server_span = TraceTestHelper.find_span!(spans, "tools/call echo")
    assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(other_client)
  end

  test "enduser.scope names the scopes the authenticator verified" do
    server_name = unique_name("trace-verified-scopes")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn _input, _ctx ->
      {:ok, %{principal: %{"sub" => "user-1"}, scopes: ["notes:read", "notes:write"]}}
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    assert %{} == FastestMCP.call_tool!(server_name, "echo", %{}, auth_input: %{})

    attrs =
      TraceTestHelper.drain_spans()
      |> TraceTestHelper.find_span!("tools/call echo")
      |> TraceTestHelper.span_attributes()

    assert attrs["enduser.id"] == "user-1"
    assert attrs["enduser.scope"] == "notes:read notes:write"
  end
end
