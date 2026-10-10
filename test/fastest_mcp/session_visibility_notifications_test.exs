defmodule FastestMCP.SessionVisibilityNotificationsTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Component
  alias FastestMCP.ComponentManager
  alias FastestMCP.Context

  test "enabling hidden components notifies every family that changed, even one empty at connect" do
    parent = self()

    server_name =
      "visibility-notify-enable-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["finance"])
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("activate_finance", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"])
        %{ok: true}
      end)

    client = start_http_client(server, parent)

    assert %{items: []} = Client.list_resources!(client)
    assert %{items: []} = Client.list_prompts!(client)
    refute Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "activate_finance", %{})

    assert Enum.sort(receive_notification_methods(3)) == [
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/tools/list_changed"
           ]

    assert Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))
    assert %{items: [%{"uri" => "resource://finance"}]} = Client.list_resources!(client)
    assert %{items: [%{"name" => "finance_prompt"}]} = Client.list_prompts!(client)
  end

  test "disabling visible components sends list-changed notifications for all changed families" do
    parent = self()

    server_name =
      "visibility-notify-disable-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("deactivate_finance", fn _args, ctx ->
        :ok = Context.disable_components(ctx, tags: ["finance"])
        %{ok: true}
      end)

    client = start_http_client(server, parent)

    assert Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))

    assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
             Client.list_resources!(client)

    assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
             Client.list_prompts!(client)

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "deactivate_finance", %{})

    assert Enum.sort(receive_notification_methods(3)) == [
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/tools/list_changed"
           ]

    refute Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))
    assert %{items: [], next_cursor: nil} = Client.list_resources!(client)
    assert %{items: [], next_cursor: nil} = Client.list_prompts!(client)
  end

  test "reset_visibility sends notifications when it restores the visible sets" do
    parent = self()

    server_name =
      "visibility-notify-reset-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["finance"])
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("activate_finance", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"])
        %{ok: true}
      end)
      |> FastestMCP.add_tool("clear_rules", fn _args, ctx ->
        :ok = Context.reset_visibility(ctx)
        %{ok: true}
      end)

    client = start_http_client(server, parent)

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "activate_finance", %{})

    assert length(receive_notification_methods(3)) == 3
    refute_receive {:visibility_notification, _payload}, 200

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "clear_rules", %{})

    assert Enum.sort(receive_notification_methods(3)) == [
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/tools/list_changed"
           ]

    refute_receive {:visibility_notification, _payload}, 200

    refute Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))
    assert %{items: []} = Client.list_resources!(client)
    assert %{items: []} = Client.list_prompts!(client)
  end

  test "component hints limit list-changed notifications to the changed family" do
    parent = self()

    server_name =
      "visibility-notify-hint-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["finance"])
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("activate_tools_only", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool])
        %{ok: true}
      end)

    client = start_http_client(server, parent)

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "activate_tools_only", %{})

    assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
    refute_receive {:visibility_notification, _payload}, 200

    assert Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))
    assert %{items: []} = Client.list_resources!(client)
    assert %{items: []} = Client.list_prompts!(client)
  end

  test "a session's visibility change notifies that session only, never 2026-07-28 listeners" do
    test_pid = self()
    server_name = unique_name("visibility-notify-scope")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("search", fn _args, _ctx -> "found" end)
    |> FastestMCP.add_tool("hide_search", fn _args, ctx ->
      :ok = Context.disable_components(ctx, names: ["search"])
      "hidden"
    end)
    |> start_server!()

    legacy =
      connect!({:in_process, server_name},
        protocol_version: "2025-11-25",
        notification_handler: &send(test_pid, {:legacy, &1["method"]})
      )

    modern = connect!({:in_process, server_name}, protocol_version: "2026-07-28")

    listener =
      Client.listen!(modern, %{"toolsListChanged" => true},
        on_notification: &send(test_pid, {:modern, &1["method"]})
      )

    assert_receive {:modern, "notifications/subscriptions/acknowledged"}

    Client.call_tool!(legacy, "hide_search", %{})
    assert_receive {:legacy, "notifications/tools/list_changed"}

    "hidden" = FastestMCP.call_tool!(server_name, "hide_search", %{}, session_id: "chat-2")
    refute_receive {:modern, "notifications/tools/list_changed"}, 200
    refute_receive {:legacy, _method}, 50

    # A change for every client reaches both.
    :ok = FastestMCP.disable_components!(server_name, names: ["hide_search"])
    assert_receive {:legacy, "notifications/tools/list_changed"}
    assert_receive {:modern, "notifications/tools/list_changed"}

    assert :ok = Client.Request.cancel!(listener, "test complete")
  end

  test "server-scoped visibility updates emit list-changed notifications" do
    parent = self()

    server_name =
      "global-visibility-notify-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )

    client = start_http_client(server, parent)

    :ok = FastestMCP.disable_components!(server_name, tags: ["finance"])

    assert Enum.sort(receive_notification_methods(3)) == [
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/tools/list_changed"
           ]

    refute Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))
    assert %{items: [], next_cursor: nil} = Client.list_resources!(client)
    assert %{items: [], next_cursor: nil} = Client.list_prompts!(client)

    :ok = FastestMCP.reset_component_visibility!(server_name)

    assert Enum.sort(receive_notification_methods(3)) == [
             "notifications/prompts/list_changed",
             "notifications/resources/list_changed",
             "notifications/tools/list_changed"
           ]

    assert Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))

    assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
             Client.list_resources!(client)

    assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
             Client.list_prompts!(client)
  end

  test "server-scoped component hints limit notifications to the changed family" do
    parent = self()

    server_name =
      "global-visibility-notify-hint-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_resource("resource://finance", fn _args, _ctx -> "finance data" end,
        tags: ["finance"]
      )
      |> FastestMCP.add_prompt(
        "finance_prompt",
        fn _args, _ctx ->
          FastestMCP.Prompts.Result.from(%{
            messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]
          })
        end,
        tags: ["finance"]
      )

    client = start_http_client(server, parent)

    :ok = FastestMCP.disable_components!(server_name, tags: ["finance"], components: [:tool])

    assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
    refute_receive {:visibility_notification, _payload}, 200

    refute Enum.any?(Client.list_tools!(client).items, &(&1["name"] == "finance_tool"))

    assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
             Client.list_resources!(client)

    assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
             Client.list_prompts!(client)
  end

  test "replacing a descriptor under the same tool name emits and invalidates the client catalog" do
    parent = self()
    server_name = "same-name-notify-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("anchor", fn _arguments, _ctx -> %{anchor: true} end)

    client = start_http_client(server, parent)

    manager = FastestMCP.component_manager!(server_name)

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "dynamic",
               fn _arguments, _ctx -> %{old: true} end,
               version: "1.0.0",
               output_schema: object_output_schema("old")
             )

    assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
    assert %{structured_content: %{"old" => true}} = Client.call_tool!(client, "dynamic", %{})

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "dynamic",
               fn _arguments, _ctx -> %{new: true} end,
               version: "1.0.0",
               output_schema: object_output_schema("new"),
               on_duplicate: :replace
             )

    assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
    assert %{structured_content: %{"new" => true}} = Client.call_tool!(client, "dynamic", %{})
  end

  defp start_http_client(server, parent) do
    start_server!(server)

    %{url: url} =
      start_http!(server.name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:visibility_notification, payload})
        end
      )

    assert_eventually(fn -> Client.info!(client).session_stream_open? end)
    client
  end

  defp receive_notification_methods(count) do
    for _ <- 1..count do
      receive do
        {:visibility_notification, %{"method" => method}} -> method
      after
        1_000 -> flunk("timed out waiting for #{count} visibility notifications")
      end
    end
  end

  defp object_output_schema(required_property) do
    %{
      "type" => "object",
      "properties" => %{required_property => %{"type" => "boolean"}},
      "required" => [required_property],
      "additionalProperties" => false
    }
  end

  defp globally_disable(server, opts) do
    disabled_names =
      opts[:names]
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    disabled_tags =
      opts[:tags]
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    FastestMCP.add_transform(server, fn component, _operation ->
      identifier = Component.identifier(component)
      tags = Map.get(component, :tags, MapSet.new())

      disable_by_name? = MapSet.size(disabled_names) > 0 and identifier in disabled_names

      disable_by_tag? =
        MapSet.size(disabled_tags) > 0 and not MapSet.disjoint?(disabled_tags, tags)

      if disable_by_name? or disable_by_tag? do
        %{component | enabled: false}
      else
        component
      end
    end)
  end
end
