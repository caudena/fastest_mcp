defmodule FastestMCP.ProviderParityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ComponentCompiler

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

  test "dynamic providers compose with local components and use get_component for lookups" do
    dynamic_tool =
      ComponentCompiler.compile(
        :tool,
        "dynamic-provider",
        "dynamic_echo",
        fn %{"value" => value}, _ctx -> %{source: "provider", value: value} end,
        []
      )

    provider = %CountingProvider{pid: self(), tool: dynamic_tool}
    server_name = "provider-parity-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("local_echo", fn %{"value" => value}, _ctx ->
        %{source: "local", value: value}
      end)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert FastestMCP.list_tools(server_name)
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["dynamic_echo", "local_echo"]

    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool(server_name, "dynamic_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
    refute_receive :list_tools_called, 50

    assert %{source: "local", value: "world"} ==
             FastestMCP.call_tool(server_name, "local_echo", %{"value" => "world"})
  end

  test "mounted servers expose child dynamic providers" do
    dynamic_tool =
      ComponentCompiler.compile(
        :tool,
        "dynamic-provider",
        "dynamic_echo",
        fn %{"value" => value}, _ctx -> %{source: "provider", value: value} end,
        []
      )

    provider = %CountingProvider{pid: self(), tool: dynamic_tool}

    parent_name =
      "provider-mounted-dynamic-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-with-provider")
      |> FastestMCP.add_provider(provider)

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert [%{name: "child_dynamic_echo"}] = FastestMCP.list_tools(parent_name)
    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool(parent_name, "child_dynamic_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
  end
end
