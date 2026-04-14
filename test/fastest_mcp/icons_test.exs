defmodule FastestMCP.IconsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "component icons are exposed through direct list APIs and transport serialization" do
    server_name = "icons-" <> Integer.to_string(System.unique_integer([:positive]))

    icons = [
      %{
        "src" => "https://example.com/icon-48.png",
        "mimeType" => "image/png",
        "sizes" => ["48x48"]
      },
      %{
        src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
        mimeType: "image/svg+xml",
        sizes: ["any"]
      }
    ]

    server =
      FastestMCP.server(server_name,
        metadata: %{website_url: "https://example.com", icons: icons}
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end, icons: icons)
      |> FastestMCP.add_resource("data://config", fn _args, _ctx -> %{ok: true} end, icons: icons)
      |> FastestMCP.add_resource_template("data://item/{id}", fn args, _ctx -> args end,
        icons: icons
      )
      |> FastestMCP.add_prompt("greet", fn _args, _ctx -> "hi" end, icons: icons)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [tool] = FastestMCP.list_tools(server_name)
    [resource] = FastestMCP.list_resources(server_name)
    [template] = FastestMCP.list_resource_templates(server_name)
    [prompt] = FastestMCP.list_prompts(server_name)
    initialize = FastestMCP.initialize(server_name)

    assert tool.icons == Enum.map(icons, &Map.new/1)
    assert resource.icons == Enum.map(icons, &Map.new/1)
    assert template.icons == Enum.map(icons, &Map.new/1)
    assert prompt.icons == Enum.map(icons, &Map.new/1)
    assert initialize["serverInfo"]["icons"] == Enum.map(icons, &Map.new/1)
    assert initialize["serverInfo"]["websiteUrl"] == "https://example.com"

    assert %{tools: [%{"icons" => serialized_tool_icons}]} =
             Engine.dispatch!(server_name, %Request{method: "tools/list", transport: :stdio})

    assert %{
             resources: [%{"icons" => serialized_resource_icons}],
             resourceTemplates: [%{"icons" => serialized_template_icons}]
           } =
             Engine.dispatch!(server_name, %Request{method: "resources/list", transport: :stdio})

    assert %{prompts: [%{"icons" => serialized_prompt_icons}]} =
             Engine.dispatch!(server_name, %Request{method: "prompts/list", transport: :stdio})

    expected = [
      %{
        "src" => "https://example.com/icon-48.png",
        "mimeType" => "image/png",
        "sizes" => ["48x48"]
      },
      %{
        "src" => "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
        "mimeType" => "image/svg+xml",
        "sizes" => ["any"]
      }
    ]

    assert serialized_tool_icons == expected
    assert serialized_resource_icons == expected
    assert serialized_template_icons == expected
    assert serialized_prompt_icons == expected
  end
end
