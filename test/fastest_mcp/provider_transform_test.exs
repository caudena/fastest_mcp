defmodule FastestMCP.ProviderTransformTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer, as: MountedServerProvider
  alias FastestMCP.ProviderTransforms.Namespace
  alias FastestMCP.ProviderTransforms.ToolTransform

  defmodule CountingProvider do
    defstruct [:pid, :tool]

    def list_components(%__MODULE__{pid: pid, tool: tool}, :tool, _operation) do
      send(pid, :list_tools_called)
      [tool]
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def get_component(%__MODULE__{pid: pid, tool: tool}, :tool, "dynamic_echo", _operation) do
      send(pid, :get_tool_called)
      tool
    end

    def get_component(%__MODULE__{}, _component_type, _identifier, _operation), do: nil
  end

  test "namespace transform prefixes tool, prompt, resource, and template identifiers" do
    child =
      FastestMCP.server("namespace-child")
      |> FastestMCP.add_tool("my_tool", fn _args, _ctx -> "ok" end)
      |> FastestMCP.add_prompt("my_prompt", fn _args, _ctx -> "prompt" end)
      |> FastestMCP.add_resource("resource://data", fn _args, _ctx -> "content" end)
      |> FastestMCP.add_resource_template("resource://{name}/data", fn %{"name" => name}, _ctx ->
        "content for #{name}"
      end)

    provider =
      child
      |> MountedServerProvider.new()
      |> Provider.add_transform(Namespace.new("ns"))

    server_name = "provider-namespace-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "ns_my_tool"}] = FastestMCP.list_tools(server_name)
    assert [%{name: "ns_my_prompt"}] = FastestMCP.list_prompts(server_name)
    assert [%{uri: "resource://ns/data"}] = FastestMCP.list_resources(server_name)

    assert [%{uri_template: "resource://ns/{name}/data"}] =
             FastestMCP.list_resource_templates(server_name)

    assert "content" == FastestMCP.read_resource(server_name, "resource://ns/data")
  end

  test "renamed provider tools are callable through reverse lookup without falling back to list" do
    dynamic_tool =
      ComponentCompiler.compile(
        :tool,
        "dynamic-provider",
        "dynamic_echo",
        fn %{"value" => value}, _ctx -> %{source: "provider", value: value} end,
        []
      )

    provider =
      %CountingProvider{pid: self(), tool: dynamic_tool}
      |> Provider.new()
      |> Provider.add_transform(ToolTransform.new(%{"dynamic_echo" => %{name: "renamed_echo"}}))

    server_name = "provider-rename-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "renamed_echo"}] = FastestMCP.list_tools(server_name)
    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool(server_name, "renamed_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
    refute_receive :list_tools_called, 50
  end

  test "stacked namespace and tool transforms stay callable" do
    child =
      FastestMCP.server("stacked-child")
      |> FastestMCP.add_tool("my_tool", fn _args, _ctx -> "success" end)

    provider =
      child
      |> MountedServerProvider.new()
      |> Provider.add_transform(Namespace.new("ns"))
      |> Provider.add_transform(ToolTransform.new(%{"ns_my_tool" => %{name: "short"}}))

    server_name = "provider-stacked-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "short"}] = FastestMCP.list_tools(server_name)
    assert "success" == FastestMCP.call_tool(server_name, "short", %{})
  end

  test "duplicate rename targets raise" do
    assert_raise ArgumentError, ~r/duplicate target name/, fn ->
      ToolTransform.new(%{
        "tool_a" => %{name: "same"},
        "tool_b" => %{name: "same"}
      })
    end
  end
end
