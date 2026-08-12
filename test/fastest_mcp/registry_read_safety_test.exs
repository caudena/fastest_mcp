defmodule FastestMCP.RegistryReadSafetyTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Registry
  alias FastestMCP.TestSupport.ServerSupervisorIsolation

  test "reads preserve their empty contracts while Registry ETS tables are absent" do
    instance_id = make_ref()
    runtime_id = make_ref()

    :ok = ServerSupervisorIsolation.terminate_unrelated_servers!()
    assert :ok = Supervisor.terminate_child(FastestMCP.Supervisor, Registry)

    try do
      assert {:error, :not_found} = Registry.lookup_server("missing")
      assert {:error, :not_found} = Registry.lookup_server_owner("missing")
      assert {:error, :not_found} = Registry.lookup_session("missing", "session")

      assert [] = Registry.list_components("missing", :tool)
      assert [] = Registry.list_components("missing", :resource_template)
      assert [] = Registry.lookup_component_candidates("missing", :tool, "tool")

      assert [] =
               Registry.lookup_component_candidates("missing", :resource_template, "memo://{id}")

      assert nil == Registry.get_component("missing", :tool, "tool")
      assert nil == Registry.get_resource_template("missing", "memo://1")
      assert nil == Registry.get_resource_target("missing", "memo://1")

      assert {:error, :not_found} = Registry.lookup_middleware_runtime(runtime_id)
      assert [] = Registry.list_middleware_runtimes(instance_id)
    after
      assert {:ok, _pid} = Supervisor.restart_child(FastestMCP.Supervisor, Registry)
    end
  end

  test "exact-version candidate reads return only the indexed version" do
    server_name = "registry-exact-version-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn _args, _context -> :v1 end, version: "1.0.0")
      |> FastestMCP.add_tool("echo", fn _args, _context -> :v2 end, version: "2.0.0")
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn _args, _context -> :v1 end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn _args, _context -> :v2 end,
        version: "2.0.0"
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{version: "1.0.0"}] =
             Registry.lookup_component_candidates(server_name, :tool, "echo", version: "1.0.0")

    assert [%{version: "2.0.0"}] =
             Registry.lookup_component_candidates(
               server_name,
               :resource_template,
               "memo://users/{id}",
               version: "2.0.0"
             )

    assert [] =
             Registry.lookup_component_candidates(server_name, :tool, "echo", version: "3.0.0")
  end
end
