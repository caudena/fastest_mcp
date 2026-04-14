defmodule FastestMCP.SessionVisibilityNotificationsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Component
  alias FastestMCP.Context

  test "enabling hidden components sends list-changed notifications for all changed families" do
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("activate_finance", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"])
        %{ok: true}
      end)

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert %{items: [], next_cursor: nil} = Client.list_resources(client)
      assert %{items: [], next_cursor: nil} = Client.list_prompts(client)
      refute Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))

      assert %{"ok" => true} = Client.call_tool(client, "activate_finance", %{})

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      assert Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))

      assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
               Client.list_resources(client)

      assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
               Client.list_prompts(client)
    after
      cleanup.()
    end
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("deactivate_finance", fn _args, ctx ->
        :ok = Context.disable_components(ctx, tags: ["finance"])
        %{ok: true}
      end)

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))

      assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
               Client.list_resources(client)

      assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
               Client.list_prompts(client)

      assert %{"ok" => true} = Client.call_tool(client, "deactivate_finance", %{})

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      refute Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))
      assert %{items: [], next_cursor: nil} = Client.list_resources(client)
      assert %{items: [], next_cursor: nil} = Client.list_prompts(client)
    after
      cleanup.()
    end
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
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

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert %{"ok" => true} = Client.call_tool(client, "activate_finance", %{})

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      assert %{"ok" => true} = Client.call_tool(client, "clear_rules", %{})

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      refute Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))
      assert %{items: [], next_cursor: nil} = Client.list_resources(client)
      assert %{items: [], next_cursor: nil} = Client.list_prompts(client)
    after
      cleanup.()
    end
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
        end,
        tags: ["finance"]
      )
      |> FastestMCP.add_tool("activate_tools_only", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool])
        %{ok: true}
      end)

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert %{"ok" => true} = Client.call_tool(client, "activate_tools_only", %{})

      assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
      refute_receive {:visibility_notification, _payload}, 200

      assert Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))
      assert %{items: [], next_cursor: nil} = Client.list_resources(client)
      assert %{items: [], next_cursor: nil} = Client.list_prompts(client)
    after
      cleanup.()
    end
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
        end,
        tags: ["finance"]
      )

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      :ok = FastestMCP.disable_components(server_name, tags: ["finance"])

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      refute Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))
      assert %{items: [], next_cursor: nil} = Client.list_resources(client)
      assert %{items: [], next_cursor: nil} = Client.list_prompts(client)

      :ok = FastestMCP.reset_component_visibility(server_name)

      assert Enum.sort(receive_notification_methods(3)) == [
               "notifications/prompts/list_changed",
               "notifications/resources/list_changed",
               "notifications/tools/list_changed"
             ]

      assert Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))

      assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
               Client.list_resources(client)

      assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
               Client.list_prompts(client)
    after
      cleanup.()
    end
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
          %{messages: [%{role: "user", content: %{type: "text", text: "finance prompt"}}]}
        end,
        tags: ["finance"]
      )

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      :ok = FastestMCP.disable_components(server_name, tags: ["finance"], components: [:tool])

      assert receive_notification_methods(1) == ["notifications/tools/list_changed"]
      refute_receive {:visibility_notification, _payload}, 200

      refute Enum.any?(Client.list_tools(client).items, &(&1["name"] == "finance_tool"))

      assert %{items: [%{"uri" => "resource://finance"}], next_cursor: nil} =
               Client.list_resources(client)

      assert %{items: [%{"name" => "finance_prompt"}], next_cursor: nil} =
               Client.list_prompts(client)
    after
      cleanup.()
    end
  end

  defp start_http_client(server_name, server, parent) do
    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:visibility_notification, payload})
        end
      )

    assert wait_for_session_stream(client) == :ok

    cleanup = fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end

    {client, cleanup}
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

  defp wait_for_session_stream(client, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_session_stream(client, deadline)
  end

  defp do_wait_for_session_stream(client, deadline) do
    cond do
      Client.session_stream_open?(client) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the client session stream to open")

      true ->
        Process.sleep(10)
        do_wait_for_session_stream(client, deadline)
    end
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
