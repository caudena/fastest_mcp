defmodule FastestMCP.DuplicatePolicyTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.ComponentManager
  alias FastestMCP.Providers.Local

  test "server on_duplicate replace and ignore control exact duplicates" do
    replace_server =
      FastestMCP.server("dup-server-replace", on_duplicate: :replace)
      |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :first} end)
      |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :second} end)

    assert match?([_], replace_server.tools)
    assert hd(replace_server.tools).compiled.(%{}, nil) == %{source: :second}

    ignore_server =
      FastestMCP.server("dup-server-ignore", on_duplicate: :ignore)
      |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :first} end)
      |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :second} end)

    assert match?([_], ignore_server.tools)
    assert hd(ignore_server.tools).compiled.(%{}, nil) == %{source: :first}
  end

  test "a name and version in several sources is listed once, as a call resolves it" do
    server_name = unique_name("dup-sources")

    provider =
      Local.new()
      |> Local.add_tool("search_notes", fn _arguments, _ctx -> %{source: :provider} end,
        description: "provider"
      )
      |> Local.add_tool("archive_notes", fn _arguments, _ctx -> %{source: :provider} end,
        description: "provider"
      )

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("search_notes", fn _arguments, _ctx -> %{source: :definition} end,
      description: "definition"
    )
    |> FastestMCP.add_tool("archive_notes", fn _arguments, _ctx -> %{source: :definition} end,
      description: "definition",
      authorization: fn _authorization -> false end
    )
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    {:ok, _tool} =
      ComponentManager.add_tool(
        server_name,
        "search_notes",
        fn _arguments, _ctx -> %{source: :manager} end,
        description: "manager"
      )

    listed = [{"archive_notes", "provider"}, {"search_notes", "definition"}]
    assert listed == Enum.map(FastestMCP.list_tools!(server_name), &{&1.name, &1.description})

    assert %{tools: tools} =
             FastestMCP.Transport.Engine.dispatch!(server_name, %FastestMCP.Transport.Request{
               method: "tools/list",
               transport: :stdio
             })

    assert listed == Enum.map(tools, &{&1["name"], &1["description"]})
    assert %{source: :definition} == FastestMCP.call_tool!(server_name, "search_notes")
    assert %{source: :provider} == FastestMCP.call_tool!(server_name, "archive_notes")
  end

  test "server on_duplicate warn logs and replaces" do
    log =
      capture_log(fn ->
        server =
          FastestMCP.server("dup-server-warn", on_duplicate: :warn)
          |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :first} end)
          |> FastestMCP.add_tool("echo", fn _arguments, _ctx -> %{source: :second} end)

        assert hd(server.tools).compiled.(%{}, nil) == %{source: :second}
      end)

    assert log =~ "already defined"
  end

  test "local providers honor duplicate policy without changing cross-provider precedence rules" do
    provider =
      Local.new(on_duplicate: :replace)
      |> Local.add_tool("echo", fn _arguments, _ctx -> %{source: :first} end)
      |> Local.add_tool("echo", fn _arguments, _ctx -> %{source: :second} end)

    [tool] = provider.tools
    assert tool.compiled.(%{}, nil) == %{source: :second}

    ignored =
      Local.new(on_duplicate: :ignore)
      |> Local.add_tool("echo", fn _arguments, _ctx -> %{source: :first} end)
      |> Local.add_tool("echo", fn _arguments, _ctx -> %{source: :second} end)

    [tool] = ignored.tools
    assert tool.compiled.(%{}, nil) == %{source: :first}
  end

  test "local provider warn policy logs and replaces through the shared registration policy" do
    log =
      capture_log(fn ->
        provider =
          Local.new(on_duplicate: :warn)
          |> Local.add_tool("echo", fn _arguments, _ctx -> :first end)
          |> Local.add_tool("echo", fn _arguments, _ctx -> :second end)

        assert hd(provider.tools).compiled.(%{}, nil) == :second
      end)

    assert log =~ "already defined"
    assert log =~ "replacing existing definition"
  end

  test "component manager adders honor duplicate policy overrides" do
    server_name = "dup-manager-" <> Integer.to_string(System.unique_integer([:positive]))

    start_server!(FastestMCP.server(server_name))

    manager = FastestMCP.component_manager!(server_name)

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "echo",
               fn _arguments, _ctx -> %{source: :first} end,
               version: "1.0.0"
             )

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "echo",
               fn _arguments, _ctx -> %{source: :second} end,
               version: "1.0.0",
               on_duplicate: :replace
             )

    assert %{source: :second} == FastestMCP.call_tool!(server_name, "echo", %{}, version: "1.0.0")

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "echo",
               fn _arguments, _ctx -> %{source: :third} end,
               version: "1.0.0",
               on_duplicate: :ignore
             )

    assert %{source: :second} == FastestMCP.call_tool!(server_name, "echo", %{}, version: "1.0.0")
  end

  test "component manager error policy raises in the caller and keeps the runtime" do
    server_name = unique_name("dup-manager-error")
    start_server!(FastestMCP.server(server_name))
    manager = FastestMCP.component_manager!(server_name)

    assert {:ok, _tool} = ComponentManager.add_tool(manager, "echo", fn _, _ -> :first end)

    assert_raise ArgumentError, ~r/already defined/, fn ->
      ComponentManager.add_tool(manager, "echo", fn _, _ -> :second end)
    end

    assert :first == FastestMCP.call_tool!(server_name, "echo", %{})
  end
end
