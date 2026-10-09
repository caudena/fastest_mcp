defmodule FastestMCP.CapabilityNegotiationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.EventBus
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "false capability values are not treated as advertised support" do
    capabilities = %{
      "tools" => %{"listChanged" => false},
      "resources" => false,
      "prompts" => nil
    }

    assert Protocol.capability?(capabilities, ["tools"])
    refute Protocol.capability_flag?(capabilities, ["tools", "listChanged"])
    refute Protocol.capability?(capabilities, ["resources"])
    refute Protocol.capability?(capabilities, ["prompts"])
    refute Protocol.server_supports_method?(capabilities, "resources/read")
    refute Protocol.server_supports_method?(capabilities, "prompts/list")
  end

  test "list-change notifications require the frozen listChanged true flag" do
    server_name = "capability-list-change-#{System.unique_integer([:positive])}"
    session_id = "capability-session"

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    ProtocolTest.initialize_session(server_name, session_id)
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    {:ok, runtime} = ServerRuntime.fetch(server_name)

    set_tools_list_changed(session_pid, false)

    assert {:ok, %{sink_ref: sink_ref}} =
             Session.attach_sink(server_name, session_id, self(), kind: :get)

    emit_component_change(runtime, server_name)
    refute_receive {:fastest_mcp_session_message, ^sink_ref, _event_id, _notification}, 100

    set_tools_list_changed(session_pid, true)
    emit_component_change(runtime, server_name)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"method" => "notifications/tools/list_changed"}}

    assert {:ok, %{server_capabilities: %{"tools" => %{"listChanged" => true}}}} =
             Session.lifecycle(server_name, session_id)
  end

  defp set_tools_list_changed(session_pid, value) do
    :sys.replace_state(session_pid, fn state ->
      %{
        state
        | server_capabilities: put_in(state.server_capabilities, ["tools", "listChanged"], value)
      }
    end)
  end

  defp emit_component_change(runtime, server_name) do
    EventBus.emit(runtime.event_bus, server_name, [:components, :changed], %{count: 1}, %{
      families: [:tools]
    })
  end
end
