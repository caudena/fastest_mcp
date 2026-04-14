defmodule FastestMCP.VisibilityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Error

  test "audience filtering hides components outside their visibility" do
    server_name = "visibility-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("model-only", fn _args, _ctx -> :ok end, visibility: [:model])
      |> FastestMCP.add_tool("app-only", fn _args, _ctx -> :ok end, visibility: [:app])

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert [%{name: "model-only"}] = FastestMCP.list_tools(server_name, audience: :model)
    assert [%{name: "app-only"}] = FastestMCP.list_tools(server_name, audience: :app)

    assert_raise Error, ~r/not visible/, fn ->
      FastestMCP.call_tool(server_name, "app-only", %{}, audience: :model)
    end
  end

  test "later transforms can disable a matching component" do
    server_name = "transform-visibility-" <> Integer.to_string(System.unique_integer([:positive]))

    transform = fn component, _operation ->
      if FastestMCP.Component.identifier(component) == "internal" do
        %{component | enabled: false}
      else
        component
      end
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_transform(transform)
      |> FastestMCP.add_tool("public", fn _args, _ctx -> :ok end)
      |> FastestMCP.add_tool("internal", fn _args, _ctx -> :ok end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert [%{name: "public"}] = FastestMCP.list_tools(server_name)

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "internal", %{})
    end
  end

  test "session visibility rules are isolated per session and affect direct access" do
    server_name =
      "session-visibility-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("visible", fn _args, _ctx -> %{ok: true} end)
      |> FastestMCP.add_tool("hide_visible", fn _args, ctx ->
        :ok = Context.disable_components(ctx, names: ["visible"], components: [:tool])
        %{ok: true}
      end)
      |> FastestMCP.add_tool("show_visible", fn _args, ctx ->
        :ok = Context.enable_components(ctx, names: ["visible"], components: [:tool])
        %{ok: true}
      end)
      |> FastestMCP.add_tool("reset_visibility", fn _args, ctx ->
        :ok = Context.reset_visibility(ctx)
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert Enum.map(FastestMCP.list_tools(server_name, session_id: "session-a"), & &1.name) ==
             ["hide_visible", "reset_visibility", "show_visible", "visible"]

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "hide_visible", %{}, session_id: "session-a")

    refute Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "visible")
           )

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-b"),
             &(&1.name == "visible")
           )

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "visible", %{}, session_id: "session-a")
    end

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "visible", %{}, session_id: "session-b")

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "show_visible", %{}, session_id: "session-a")

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "visible")
           )

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "hide_visible", %{}, session_id: "session-a")

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "reset_visibility", %{}, session_id: "session-a")

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "visible")
           )
  end

  test "session rules persist across requests and are stored in session state" do
    server_name =
      "session-rules-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["finance"])
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_tool("activate_finance", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"])

        %{rules: Context.get_state(ctx, {:fastest_mcp, :visibility_rules}, [])}
      end)
      |> FastestMCP.add_tool("check_rules", fn _args, ctx ->
        %{count: length(Context.get_state(ctx, {:fastest_mcp, :visibility_rules}, []))}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    refute Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "finance_tool")
           )

    assert %{
             rules: [
               %{
                 action: :enable,
                 tags: tags,
                 names: nil,
                 keys: nil,
                 components: nil,
                 match_all: false
               }
             ]
           } =
             FastestMCP.call_tool(server_name, "activate_finance", %{}, session_id: "session-a")

    assert Enum.sort(tags) == ["finance"]

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "finance_tool")
           )

    refute Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-b"),
             &(&1.name == "finance_tool")
           )

    assert %{count: 1} ==
             FastestMCP.call_tool(server_name, "check_rules", %{}, session_id: "session-a")
  end

  test "version selectors enable only matching versions" do
    server_name =
      "session-version-rules-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(names: ["old_tool", "new_tool"])
      |> FastestMCP.add_tool("old_tool", fn _args, _ctx -> "old" end, version: "1.0.0")
      |> FastestMCP.add_tool("new_tool", fn _args, _ctx -> "new" end, version: "2.0.0")
      |> FastestMCP.add_tool("enable_v2_only", fn _args, ctx ->
        :ok = Context.enable_components(ctx, version: %{gte: "2.0.0"})
        %{rules: Context.get_state(ctx, {:fastest_mcp, :visibility_rules}, [])}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             rules: [
               %{
                 action: :enable,
                 version: %{eq: nil, gt: nil, gte: "2.0.0", lt: nil, lte: nil}
               }
             ]
           } = FastestMCP.call_tool(server_name, "enable_v2_only", %{}, session_id: "session-a")

    visible =
      FastestMCP.list_tools(server_name, session_id: "session-a")
      |> Enum.map(&{&1.name, &1.version})

    assert {"new_tool", "2.0.0"} in visible
    refute {"old_tool", "1.0.0"} in visible
  end

  test "multiple rules accumulate and later rules override earlier ones" do
    server_name =
      "session-rule-order-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("test_tool", fn _args, _ctx -> "test" end, tags: ["test"])
      |> FastestMCP.add_tool("toggle_test", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["test"])
        :ok = Context.disable_components(ctx, tags: ["test"])
        %{rules: Context.get_state(ctx, {:fastest_mcp, :visibility_rules}, [])}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             rules: [
               %{action: :enable, tags: ["test"]},
               %{action: :disable, tags: ["test"]}
             ]
           } =
             FastestMCP.call_tool(server_name, "toggle_test", %{}, session_id: "session-a")

    refute Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "test_tool")
           )
  end

  test "session visibility applies to resources and prompts and reset restores global state" do
    server_name =
      "session-surface-visibility-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["finance"])
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
        %{count: length(Context.get_state(ctx, {:fastest_mcp, :visibility_rules}, []))}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [] == FastestMCP.list_resources(server_name, session_id: "session-a")
    assert [] == FastestMCP.list_prompts(server_name, session_id: "session-a")

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "activate_finance", %{}, session_id: "session-a")

    assert [%{uri: "resource://finance"}] =
             FastestMCP.list_resources(server_name, session_id: "session-a")

    assert [%{name: "finance_prompt"}] =
             FastestMCP.list_prompts(server_name, session_id: "session-a")

    assert "finance data" ==
             FastestMCP.read_resource(server_name, "resource://finance", session_id: "session-a")

    assert %{messages: [%{content: %{text: "finance prompt"}}]} =
             FastestMCP.render_prompt(server_name, "finance_prompt", %{}, session_id: "session-a")

    assert %{count: 0} ==
             FastestMCP.call_tool(server_name, "clear_rules", %{}, session_id: "session-a")

    assert [] == FastestMCP.list_resources(server_name, session_id: "session-a")
    assert [] == FastestMCP.list_prompts(server_name, session_id: "session-a")
  end

  test "repeated disable and reset cycles restore visibility every time" do
    server_name =
      "session-reset-loop-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("create_project", fn _args, _ctx -> "created" end, tags: ["system"])
      |> FastestMCP.add_tool("enter_env", fn _args, ctx ->
        :ok = Context.disable_components(ctx, tags: ["system"])
        %{ok: true}
      end)
      |> FastestMCP.add_tool("exit_env", fn _args, ctx ->
        :ok = Context.reset_visibility(ctx)
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    for _iteration <- 1..3 do
      assert Enum.any?(
               FastestMCP.list_tools(server_name, session_id: "session-a"),
               &(&1.name == "create_project")
             )

      assert %{ok: true} ==
               FastestMCP.call_tool(server_name, "enter_env", %{}, session_id: "session-a")

      refute Enum.any?(
               FastestMCP.list_tools(server_name, session_id: "session-a"),
               &(&1.name == "create_project")
             )

      assert %{ok: true} ==
               FastestMCP.call_tool(server_name, "exit_env", %{}, session_id: "session-a")
    end

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "create_project")
           )
  end

  test "session visibility changes do not leak to concurrent or later sessions" do
    server_name =
      "session-leak-check-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("shared_tool", fn _args, _ctx -> "shared" end, tags: ["system"])
      |> FastestMCP.add_tool("disable_system", fn _args, ctx ->
        :ok = Context.disable_components(ctx, tags: ["system"])
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    parent = self()

    session_a =
      Task.async(fn ->
        assert %{ok: true} ==
                 FastestMCP.call_tool(server_name, "disable_system", %{}, session_id: "session-a")

        send(parent, :session_a_disabled)
        :timer.sleep(200)
      end)

    assert_receive :session_a_disabled, 1_000

    assert Task.async(fn ->
             Enum.any?(
               FastestMCP.list_tools(server_name, session_id: "session-b"),
               &(&1.name == "shared_tool")
             )
           end)
           |> Task.await(1_000)

    Task.await(session_a, 1_000)

    assert Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-c"),
             &(&1.name == "shared_tool")
           )
  end

  test "many concurrent sessions remain isolated" do
    server_name =
      "many-session-isolation-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> globally_disable(tags: ["premium"])
      |> FastestMCP.add_tool("premium_tool", fn _args, _ctx -> "premium" end, tags: ["premium"])
      |> FastestMCP.add_tool("activate_premium", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["premium"])
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    activated =
      0..4
      |> Task.async_stream(
        fn index ->
          session_id = "activated-#{index}"

          assert %{ok: true} ==
                   FastestMCP.call_tool(server_name, "activate_premium", %{},
                     session_id: session_id
                   )

          {session_id,
           Enum.any?(
             FastestMCP.list_tools(server_name, session_id: session_id),
             &(&1.name == "premium_tool")
           )}
        end,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    non_activated =
      0..4
      |> Task.async_stream(
        fn index ->
          session_id = "non-activated-#{index}"

          {session_id,
           Enum.any?(
             FastestMCP.list_tools(server_name, session_id: session_id),
             &(&1.name == "premium_tool")
           )}
        end,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(activated, fn {_session_id, sees_tool?} -> sees_tool? end)
    assert Enum.all?(non_activated, fn {_session_id, sees_tool?} -> not sees_tool? end)
  end

  test "server-scoped visibility is authoritative over session re-enables" do
    server_name =
      "global-visibility-authority-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_tool("activate_finance", fn _args, ctx ->
        :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool])
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok = FastestMCP.disable_components(server_name, tags: ["finance"], components: [:tool])

    refute Enum.any?(FastestMCP.list_tools(server_name), &(&1.name == "finance_tool"))

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "finance_tool", %{})
    end

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "activate_finance", %{}, session_id: "session-a")

    refute Enum.any?(
             FastestMCP.list_tools(server_name, session_id: "session-a"),
             &(&1.name == "finance_tool")
           )

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "finance_tool", %{}, session_id: "session-a")
    end
  end

  test "server-scoped only allowlists selected tool subsets" do
    server_name =
      "global-visibility-only-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_tool("ops_tool", fn _args, _ctx -> "ops" end, tags: ["ops"])

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok =
      FastestMCP.enable_components(server_name,
        tags: ["finance"],
        components: [:tool],
        only: true
      )

    assert ["finance_tool"] == Enum.map(FastestMCP.list_tools(server_name), & &1.name)
    assert "finance" == FastestMCP.call_tool(server_name, "finance_tool", %{})

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "ops_tool", %{})
    end
  end

  test "session-scoped only allowlists selected tool subsets" do
    server_name =
      "session-visibility-only-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("finance_tool", fn _args, _ctx -> "finance" end, tags: ["finance"])
      |> FastestMCP.add_tool("ops_tool", fn _args, _ctx -> "ops" end, tags: ["ops"])
      |> FastestMCP.add_tool(
        "focus_finance",
        fn _args, ctx ->
          :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool], only: true)
          %{ok: true}
        end,
        tags: ["finance"]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{ok: true} ==
             FastestMCP.call_tool(server_name, "focus_finance", %{}, session_id: "session-a")

    assert ["finance_tool", "focus_finance"] ==
             FastestMCP.list_tools(server_name, session_id: "session-a")
             |> Enum.map(& &1.name)
             |> Enum.sort()

    assert ["finance_tool", "focus_finance", "ops_tool"] ==
             FastestMCP.list_tools(server_name, session_id: "session-b")
             |> Enum.map(& &1.name)
             |> Enum.sort()
  end

  test "server-scoped selectors support keys and match_all component filters" do
    server_name =
      "global-visibility-selectors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("alpha", fn _args, _ctx -> "alpha" end)
      |> FastestMCP.add_tool("beta", fn _args, _ctx -> "beta" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    beta_key =
      FastestMCP.list_tools(server_name)
      |> Enum.find(&(&1.name == "beta"))
      |> Map.fetch!(:key)

    :ok = FastestMCP.disable_components(server_name, keys: [beta_key], components: [:tool])

    assert ["alpha"] == Enum.map(FastestMCP.list_tools(server_name), & &1.name)
    assert "alpha" == FastestMCP.call_tool(server_name, "alpha", %{})

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "beta", %{})
    end

    :ok = FastestMCP.reset_component_visibility(server_name)
    :ok = FastestMCP.disable_components(server_name, components: [:tool], match_all: true)

    assert [] == FastestMCP.list_tools(server_name)

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "alpha", %{})
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
