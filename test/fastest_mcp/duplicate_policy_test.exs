defmodule FastestMCP.DuplicatePolicyTest do
  use ExUnit.Case, async: false

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

  test "component manager adders honor duplicate policy overrides" do
    server_name = "dup-manager-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

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

    assert %{source: :second} == FastestMCP.call_tool(server_name, "echo", %{}, version: "1.0.0")

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "echo",
               fn _arguments, _ctx -> %{source: :third} end,
               version: "1.0.0",
               on_duplicate: :ignore
             )

    assert %{source: :second} == FastestMCP.call_tool(server_name, "echo", %{}, version: "1.0.0")
  end
end
