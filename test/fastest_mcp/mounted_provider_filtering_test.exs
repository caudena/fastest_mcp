defmodule FastestMCP.MountedProviderFilteringTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error

  test "include_tags on a mount filters mounted tools, resources, and prompts" do
    parent_name =
      "mounted-filter-include-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("mounted-child")
      |> FastestMCP.add_tool("allowed_tool", fn _args, _ctx -> "allowed" end, tags: ["allowed"])
      |> FastestMCP.add_tool("blocked_tool", fn _args, _ctx -> "blocked" end, tags: ["blocked"])
      |> FastestMCP.add_resource("data://allowed", fn _args, _ctx -> "allowed" end,
        tags: ["allowed"]
      )
      |> FastestMCP.add_resource("data://blocked", fn _args, _ctx -> "blocked" end,
        tags: ["blocked"]
      )
      |> FastestMCP.add_prompt("allowed_prompt", fn _args, _ctx -> "allowed" end,
        tags: ["allowed"]
      )
      |> FastestMCP.add_prompt("blocked_prompt", fn _args, _ctx -> "blocked" end,
        tags: ["blocked"]
      )

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, include_tags: ["allowed"])

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert Enum.map(FastestMCP.list_tools(parent_name), & &1.name) == ["allowed_tool"]
    assert Enum.map(FastestMCP.list_resources(parent_name), & &1.uri) == ["data://allowed"]
    assert Enum.map(FastestMCP.list_prompts(parent_name), & &1.name) == ["allowed_prompt"]

    assert "allowed" == FastestMCP.call_tool(parent_name, "allowed_tool", %{})

    assert_raise Error, ~r/unknown tool "blocked_tool"/, fn ->
      FastestMCP.call_tool(parent_name, "blocked_tool", %{})
    end
  end

  test "exclude_tags on a mount hides matching mounted components" do
    parent_name =
      "mounted-filter-exclude-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("mounted-child-exclude")
      |> FastestMCP.add_tool("prod_tool", fn _args, _ctx -> "prod" end, tags: ["production"])
      |> FastestMCP.add_tool("blocked_tool", fn _args, _ctx -> "blocked" end, tags: ["blocked"])

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, exclude_tags: ["blocked"])

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert Enum.map(FastestMCP.list_tools(parent_name), & &1.name) == ["prod_tool"]
  end
end
