defmodule FastestMCP.CapabilityNegotiationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionNotificationSubscriber
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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    ProtocolTest.initialize_session(server_name, session_id)
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    {:ok, runtime} = ServerRuntime.fetch(server_name)

    set_tools_list_changed(session_pid, false)

    assert {:ok, subscriber} =
             SessionNotificationSubscriber.start_link(
               server_name: server_name,
               session_id: session_id,
               event_bus: runtime.event_bus,
               task_store: runtime.task_store,
               owner: self(),
               target: self()
             )

    send_component_change(subscriber, server_name)
    refute_receive {:fastest_mcp_session_notification, ^server_name, _notification}, 100

    set_tools_list_changed(session_pid, true)
    send_component_change(subscriber, server_name)

    assert_receive {:fastest_mcp_session_notification, ^server_name,
                    %{"method" => "notifications/tools/list_changed"}},
                   500

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

  defp send_component_change(subscriber, server_name) do
    send(
      subscriber,
      {:fastest_mcp_event, server_name, [:components, :changed], %{count: 1},
       %{families: [:tools]}}
    )
  end
end
