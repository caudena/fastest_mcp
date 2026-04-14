defmodule FastestMCP.VersioningTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "highest version wins by default and exact versions remain callable" do
    server_name = "versioning-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0")
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0")

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert 2 == FastestMCP.call_tool(server_name, "calc", %{})
    assert 1 == FastestMCP.call_tool(server_name, "calc", %{}, version: "1.0")
    assert 2 == FastestMCP.call_tool(server_name, "calc", %{}, version: "2.0")
  end

  test "mixing versioned and unversioned definitions is rejected" do
    server = FastestMCP.server("mixing-" <> Integer.to_string(System.unique_integer([:positive])))

    assert_raise ArgumentError, ~r/cannot mix unversioned and versioned definitions/, fn ->
      server
      |> FastestMCP.add_resource("file:///config", fn _args, _ctx -> "v1" end, version: "1.0")
      |> FastestMCP.add_resource("file:///config", fn _args, _ctx -> "unversioned" end)
    end
  end

  test "invalid versions are rejected early" do
    assert_raise ArgumentError, ~r/cannot contain '@'/, fn ->
      FastestMCP.server(
        "invalid-version-" <> Integer.to_string(System.unique_integer([:positive]))
      )
      |> FastestMCP.add_tool("bad", fn _args, _ctx -> :ok end, version: "1.0@beta")
    end
  end

  test "transport version selection falls back to the highest visible tool version" do
    server_name =
      "versioning-transport-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok =
      FastestMCP.disable_components(server_name,
        names: ["calc"],
        version: %{eq: "2.0.0"},
        components: [:tool]
      )

    assert [{"calc", "1.0.0"}] ==
             FastestMCP.list_tools(server_name)
             |> Enum.map(&{&1.name, &1.version})

    assert 1 == FastestMCP.call_tool(server_name, "calc", %{})

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool(server_name, "calc", %{}, version: "2.0.0")
    end

    assert %{"structuredContent" => 1} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "calc", "arguments" => %{}}
             })

    assert %{"structuredContent" => 1} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{
                 "name" => "calc",
                 "arguments" => %{},
                 "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
               }
             })

    assert_raise Error, ~r/disabled/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        payload: %{
          "name" => "calc",
          "arguments" => %{},
          "_meta" => %{"fastestmcp" => %{"version" => "2.0.0"}}
        }
      })
    end
  end

  test "unrelated transport metadata is ignored for version selection" do
    server_name =
      "versioning-vendor-meta-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "1.0.0"} end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "2.0.0"} end,
        version: "2.0.0"
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"structuredContent" => 2} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{
                 "name" => "calc",
                 "arguments" => %{},
                 "_meta" => %{"vendor" => %{"version" => "1.0.0", "stable" => true}}
               }
             })

    assert %{"contents" => [%{"text" => "{\"version\":\"2.0.0\"}"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{
                 "uri" => "memo://config",
                 "_meta" => %{"vendor" => %{"version" => "1.0.0", "stable" => true}}
               }
             })
  end

  test "transport version selection and list visibility work for resources and templates" do
    server_name =
      "resource-versioning-transport-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "1.0.0"} end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "2.0.0"} end,
        version: "2.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> %{id: id, version: "1.0.0"} end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> %{id: id, version: "2.0.0"} end,
        version: "2.0.0"
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok =
      FastestMCP.disable_components(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    assert [{"memo://config", "1.0.0"}] ==
             FastestMCP.list_resources(server_name)
             |> Enum.map(&{&1.uri, &1.version})

    assert [{"memo://users/{id}", "1.0.0"}] ==
             FastestMCP.list_resource_templates(server_name)
             |> Enum.map(&{&1.uri_template, &1.version})

    assert %{version: "1.0.0"} == FastestMCP.read_resource(server_name, "memo://config")

    assert %{id: "42", version: "1.0.0"} ==
             FastestMCP.read_resource(server_name, "memo://users/42")

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.read_resource(server_name, "memo://config", version: "2.0.0")
    end

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.read_resource(server_name, "memo://users/42", version: "2.0.0")
    end

    assert %{"contents" => [%{"text" => "{\"version\":\"1.0.0\"}"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{"uri" => "memo://config"}
             })

    assert %{"contents" => [%{"text" => "{\"id\":\"42\",\"version\":\"1.0.0\"}"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{"uri" => "memo://users/42"}
             })

    assert %{"contents" => [%{"text" => "{\"version\":\"1.0.0\"}"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{
                 "uri" => "memo://config",
                 "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
               }
             })

    assert %{"contents" => [%{"text" => "{\"id\":\"42\",\"version\":\"1.0.0\"}"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{
                 "uri" => "memo://users/42",
                 "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
               }
             })

    assert_raise Error, ~r/disabled/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "resources/read",
        transport: :stdio,
        payload: %{
          "uri" => "memo://config",
          "_meta" => %{"fastestmcp" => %{"version" => "2.0.0"}}
        }
      })
    end

    assert_raise Error, ~r/disabled/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "resources/read",
        transport: :stdio,
        payload: %{
          "uri" => "memo://users/42",
          "_meta" => %{"fastestmcp" => %{"version" => "2.0.0"}}
        }
      })
    end

    assert %{
             resources: [
               %{"uri" => "memo://config", "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}}
             ],
             resourceTemplates: [
               %{
                 "uriTemplate" => "memo://users/{id}",
                 "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })
  end
end
