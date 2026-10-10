defmodule FastestMCP.ComponentIndexTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.ComponentIndex

  test "exact-version candidate reads return only the indexed version" do
    server =
      FastestMCP.server(unique_name("component-index"))
      |> FastestMCP.add_tool("echo", fn _args, _context -> :v1 end, version: "1.0.0")
      |> FastestMCP.add_tool("echo", fn _args, _context -> :v2 end, version: "2.0.0")
      |> FastestMCP.add_resource_template("memo://users/{id}", fn _args, _context -> :v1 end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource_template("memo://users/{id}", fn _args, _context -> :v2 end,
        version: "2.0.0"
      )
      |> start_server!()

    assert [%{version: "1.0.0"}] = ComponentIndex.candidates(server.name, :tool, "echo", "1.0.0")

    assert [%{version: "2.0.0"}, %{version: "1.0.0"}] =
             ComponentIndex.candidates(server.name, :tool, "echo")

    assert [%{version: "2.0.0"}] =
             ComponentIndex.candidates(
               server.name,
               :resource_template,
               "memo://users/{id}",
               "2.0.0"
             )

    assert [] = ComponentIndex.candidates(server.name, :tool, "echo", "3.0.0")
  end

  test "reads of a stopped server return no components" do
    server =
      FastestMCP.server(unique_name("stopped-index"))
      |> FastestMCP.add_tool("echo", fn args, _ctx -> args end)

    start_server!(server)
    assert [%{name: "echo"}] = ComponentIndex.list(server.name, :tool)
    assert :ok = FastestMCP.stop_server(server.name)
    assert [] = ComponentIndex.list(server.name, :tool)
  end
end
