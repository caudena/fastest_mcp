defmodule FastestMCP.ComponentManagerTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ComponentManager
  alias FastestMCP.Error

  test "dynamic tools can be added, versioned, disabled, enabled, and removed through the public pipeline" do
    server_name =
      "component-manager-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    assert [] == FastestMCP.list_tools(server_name)

    assert {:ok, _tool_v1} =
             ComponentManager.add_tool(
               manager,
               "dynamic.echo",
               fn %{"value" => value}, _ctx -> %{version: 1, value: value} end,
               version: "1.0.0"
             )

    assert {:ok, _tool_v2} =
             ComponentManager.add_tool(
               manager,
               "dynamic.echo",
               fn %{"value" => value}, _ctx -> %{version: 2, value: value} end,
               version: "2.0.0"
             )

    assert Enum.map(FastestMCP.list_tools(server_name), & &1.name) == [
             "dynamic.echo",
             "dynamic.echo"
           ]

    assert %{version: 2, value: "hi"} ==
             FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "hi"})

    assert %{version: 1, value: "hi"} ==
             FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "hi"},
               version: "1.0.0"
             )

    assert {:ok, [_disabled]} =
             ComponentManager.disable_tool(manager, "dynamic.echo", version: "2.0.0")

    assert %{version: 1, value: "fallback"} ==
             FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "fallback"})

    assert {:ok, disabled_tools} =
             ComponentManager.list(manager, :tool, include_disabled: true)
             |> then(fn tools -> {:ok, tools} end)

    assert Enum.count(disabled_tools, &(&1.enabled == false)) == 1

    assert {:ok, [_enabled]} =
             ComponentManager.enable_tool(manager, "dynamic.echo", version: "2.0.0")

    assert %{version: 2, value: "again"} ==
             FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "again"})

    assert {:ok, removed} =
             ComponentManager.remove_tool(manager, "dynamic.echo", version: "2.0.0")

    assert Enum.map(removed, & &1.version) == ["2.0.0"]

    assert %{version: 1, value: "left"} ==
             FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "left"})

    assert {:ok, removed} = ComponentManager.remove_tool(manager, "dynamic.echo")
    assert Enum.map(removed, & &1.version) == ["1.0.0"]

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "missing"})
      end

    assert error.code == :not_found
  end

  test "dynamic resources, templates, and prompts participate in list/get/read paths" do
    server_name =
      "component-manager-surface-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    assert {:ok, _resource} =
             ComponentManager.add_resource(
               manager,
               "config://runtime",
               fn _args, _ctx -> %{status: "ok"} end
             )

    assert {:ok, _template} =
             ComponentManager.add_resource_template(
               manager,
               "users://{id}",
               fn arguments, _ctx -> arguments end
             )

    assert {:ok, _prompt} =
             ComponentManager.add_prompt(
               manager,
               "dynamic_greet",
               fn %{"name" => name}, _ctx ->
                 %{
                   messages: [
                     %{
                       role: "assistant",
                       content: %{type: "text", text: "Hello, #{name}!"}
                     }
                   ]
                 }
               end
             )

    assert Enum.map(FastestMCP.list_resources(server_name), & &1.uri) == ["config://runtime"]

    assert Enum.map(FastestMCP.list_resource_templates(server_name), & &1.uri_template) == [
             "users://{id}"
           ]

    assert Enum.map(FastestMCP.list_prompts(server_name), & &1.name) == ["dynamic_greet"]

    assert %{status: "ok"} == FastestMCP.read_resource(server_name, "config://runtime")
    assert %{"id" => "42"} == FastestMCP.read_resource(server_name, "users://42")

    assert %{
             messages: [
               %{
                 role: "assistant",
                 content: %{type: "text", text: "Hello, Nate!"}
               }
             ]
           } = FastestMCP.render_prompt(server_name, "dynamic_greet", %{"name" => "Nate"})

    assert {:ok, [_]} = ComponentManager.disable_resource(manager, "config://runtime")

    resource_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "config://runtime")
      end

    assert resource_error.code == :not_found

    assert {:ok, [_]} = ComponentManager.disable_resource_template(manager, "users://{id}")

    template_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "users://42")
      end

    assert template_error.code == :not_found

    assert {:ok, [_]} = ComponentManager.disable_prompt(manager, "dynamic_greet")

    prompt_error =
      assert_raise Error, fn ->
        FastestMCP.render_prompt(server_name, "dynamic_greet", %{"name" => "Nate"})
      end

    assert prompt_error.code == :not_found
  end

  test "dynamic tools take precedence over static registry entries until disabled" do
    server_name =
      "component-manager-tool-collision-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :static} end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "echo",
               fn _arguments, _ctx -> %{source: :dynamic} end,
               version: "2.0.0"
             )

    assert [{"echo", nil}, {"echo", "2.0.0"}] ==
             FastestMCP.list_tools(server_name)
             |> Enum.map(&{&1.name, &1.version})
             |> Enum.sort()

    assert %{source: :dynamic} == FastestMCP.call_tool(server_name, "echo", %{})

    assert {:ok, [_]} = ComponentManager.disable_tool(manager, "echo", version: "2.0.0")

    assert %{source: :static} == FastestMCP.call_tool(server_name, "echo", %{})
  end

  test "dynamic resources take precedence over static registry entries until disabled" do
    server_name =
      "component-manager-resource-collision-" <>
        Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("config://runtime", fn _arguments, _ctx -> %{source: :static} end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    assert {:ok, _resource} =
             ComponentManager.add_resource(
               manager,
               "config://runtime",
               fn _arguments, _ctx -> %{source: :dynamic} end,
               version: "2.0.0"
             )

    assert [{"config://runtime", nil}, {"config://runtime", "2.0.0"}] ==
             FastestMCP.list_resources(server_name)
             |> Enum.map(&{&1.uri, &1.version})
             |> Enum.sort()

    assert %{source: :dynamic} == FastestMCP.read_resource(server_name, "config://runtime")

    assert {:ok, [_]} =
             ComponentManager.disable_resource(manager, "config://runtime", version: "2.0.0")

    assert %{source: :static} == FastestMCP.read_resource(server_name, "config://runtime")
  end

  test "dynamic resource templates take precedence over static registry entries until disabled" do
    server_name =
      "component-manager-template-collision-" <>
        Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("users://{id}", fn %{"id" => id}, _ctx ->
        %{id: id, source: :static}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    assert {:ok, _template} =
             ComponentManager.add_resource_template(
               manager,
               "users://{id}",
               fn %{"id" => id}, _ctx -> %{id: id, source: :dynamic} end,
               version: "2.0.0"
             )

    assert [{"users://{id}", nil}, {"users://{id}", "2.0.0"}] ==
             FastestMCP.list_resource_templates(server_name)
             |> Enum.map(&{&1.uri_template, &1.version})
             |> Enum.sort()

    assert %{id: "42", source: :dynamic} == FastestMCP.read_resource(server_name, "users://42")

    assert {:ok, [_]} =
             ComponentManager.disable_resource_template(manager, "users://{id}", version: "2.0.0")

    assert %{id: "42", source: :static} == FastestMCP.read_resource(server_name, "users://42")
  end
end
