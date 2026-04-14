defmodule FastestMCP.ServerTracingTest do
  use ExUnit.Case, async: false

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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert "Hello, World!" == FastestMCP.call_tool(server_name, "greet", %{"name" => "World"})

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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("users://{user_id}/profile", fn %{"user_id" => user_id},
                                                                          _ctx ->
        "profile for #{user_id}"
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert "profile for 123" == FastestMCP.read_resource(server_name, "users://123/profile")

    spans = TraceTestHelper.drain_spans()
    span = TraceTestHelper.find_span!(spans, "resources/read users://123/profile")
    attrs = TraceTestHelper.span_attributes(span)

    assert TraceTestHelper.span_kind(span) == :server
    assert attrs["mcp.method.name"] == "resources/read"
    assert attrs["mcp.resource.uri"] == "users://123/profile"
    assert attrs["rpc.method"] == "resources/read"
    assert attrs["fastestmcp.component.type"] == "resource_template"
    assert attrs["fastestmcp.component.key"] == "template:users://{user_id}/profile@"
  end

  test "failed operations mark the span as an error" do
    server_name = "trace-error-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("explode", fn _args, _ctx -> raise "boom" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise Error, fn ->
      FastestMCP.call_tool(server_name, "explode", %{})
    end

    spans = TraceTestHelper.drain_spans()
    span = TraceTestHelper.find_span!(spans, "tools/call explode")

    assert TraceTestHelper.span_status_code(span) == :error
  end

  test "authenticated operations include auth attributes and continue an incoming trace" do
    server_name = "trace-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "valid-token" => %{client_id: "test-client-123", scopes: ["read", "write"]}
        }
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    Tracer.with_span "client-request" do
      headers = FastestMCP.Telemetry.inject_trace_context()

      assert %{"value" => "ok"} ==
               FastestMCP.call_tool(server_name, "echo", %{"value" => "ok"},
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
    assert is_binary(attrs["mcp.session.id"])
    assert TraceTestHelper.trace_id(server_span) == TraceTestHelper.trace_id(parent_span)
    assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(parent_span)
  end
end
