defmodule FastestMCP.ProviderTracingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.TraceTestHelper

  setup do
    TraceTestHelper.set_exporter(self())
    _ = TraceTestHelper.drain_spans()
    :ok
  end

  test "mounted tool calls create delegate spans between parent and child server spans" do
    parent_name = "trace-parent-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-server")
      |> FastestMCP.add_tool("greet", fn _args, _ctx -> "Hello" end)

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "ns")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert "Hello" == FastestMCP.call_tool(parent_name, "ns_greet", %{})

    spans = TraceTestHelper.drain_spans()
    parent_span = TraceTestHelper.find_span!(spans, "tools/call ns_greet")
    delegate_span = TraceTestHelper.find_span!(spans, "delegate greet")
    child_span = TraceTestHelper.find_span!(spans, "tools/call greet")

    delegate_attrs = TraceTestHelper.span_attributes(delegate_span)

    assert delegate_attrs["fastestmcp.provider.type"] == "MountedServerProvider"
    assert delegate_attrs["fastestmcp.component.key"] == "greet"
    assert TraceTestHelper.parent_span_id(delegate_span) == TraceTestHelper.span_id(parent_span)
    assert TraceTestHelper.parent_span_id(child_span) == TraceTestHelper.span_id(delegate_span)
    assert TraceTestHelper.trace_id(child_span) == TraceTestHelper.trace_id(parent_span)
  end
end
