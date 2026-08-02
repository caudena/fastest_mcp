defmodule FastestMCP.VersioningTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Providers.Local
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

  test "provider candidates fall back to the highest visible version and expose what executed" do
    parent = self()
    server_name = "provider-version-fallback-#{System.unique_integer([:positive])}"

    provider =
      Local.new(name: "versioned-provider")
      |> Local.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
      |> Local.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")

    transform = fn component, _operation ->
      if FastestMCP.Component.identifier(component) == "calc" do
        send(parent, {:transformed, component.version})

        if component.version == "2.0.0" do
          Map.replace!(component, :enabled, false)
        else
          component
        end
      else
        component
      end
    end

    server =
      FastestMCP.server(server_name, transforms: [transform])
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert {1, %{name: "calc", version: "1.0.0", enabled: true}} =
             OperationPipeline.call_tool_with_component(server_name, "calc", %{})

    assert_receive {:transformed, "2.0.0"}
    assert_receive {:transformed, "1.0.0"}
    refute_receive {:transformed, _version}
  end

  test "unversioned resolution falls back past unauthorized tools and templates" do
    server_name = "authorization-version-fallback-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("secure", fn _args, _ctx -> "tool_v1" end,
        version: "1.0.0",
        auth: fn _context -> true end
      )
      |> FastestMCP.add_tool("secure", fn _args, _ctx -> "tool_v2" end,
        version: "2.0.0",
        auth: fn _context -> false end
      )
      |> FastestMCP.add_resource_template(
        "secure://items/{id}",
        fn %{"id" => id}, _ctx -> "template_v1:#{id}" end,
        version: "1.0.0",
        auth: fn _context -> :ok end
      )
      |> FastestMCP.add_resource_template(
        "secure://items/{id}",
        fn %{"id" => id}, _ctx -> "template_v2:#{id}" end,
        version: "2.0.0",
        auth: fn _context -> nil end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert "tool_v1" == FastestMCP.call_tool(server_name, "secure", %{})
    assert "template_v1:42" == FastestMCP.read_resource(server_name, "secure://items/42")

    tool_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "secure", %{}, version: "2.0.0")
      end

    assert tool_error.code == :forbidden

    template_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "secure://items/42", version: "2.0.0")
      end

    assert template_error.code == :forbidden
  end

  test "provider resource and template candidates preserve lower-version fallback" do
    server_name = "provider-resource-fallback-#{System.unique_integer([:positive])}"

    provider =
      Local.new(name: "versioned-resources")
      |> Local.add_resource("memo://config", fn _args, _ctx -> "resource_v1" end,
        version: "1.0.0"
      )
      |> Local.add_resource("memo://config", fn _args, _ctx -> "resource_v2" end,
        version: "2.0.0"
      )
      |> Local.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> "template_v1:#{id}" end,
        version: "1.0.0"
      )
      |> Local.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> "template_v2:#{id}" end,
        version: "2.0.0"
      )

    server = FastestMCP.server(server_name) |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok =
      FastestMCP.disable_components(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    assert {"resource_v1", %{uri: "memo://config", version: "1.0.0"}} =
             OperationPipeline.read_resource_with_component(server_name, "memo://config")

    assert {"template_v1:42", %{uri_template: "memo://users/{id}", version: "1.0.0"}} =
             OperationPipeline.read_resource_with_component(server_name, "memo://users/42")
  end

  test "mounted candidates preserve lower-version fallback without list resolution" do
    server_name = "mounted-version-fallback-#{System.unique_integer([:positive])}"

    child =
      FastestMCP.server("mounted-version-child-#{System.unique_integer([:positive])}")
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> "resource_v1" end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> "resource_v2" end,
        version: "2.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> "template_v1:#{id}" end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> "template_v2:#{id}" end,
        version: "2.0.0"
      )

    disable_v2 = fn component, _operation ->
      if component.version == "2.0.0",
        do: Map.replace!(component, :enabled, false),
        else: component
    end

    server =
      FastestMCP.server(server_name, transforms: [disable_v2])
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 1 == FastestMCP.call_tool(server_name, "child_calc", %{})
    assert "resource_v1" == FastestMCP.read_resource(server_name, "memo://child/config")

    assert "template_v1:42" ==
             FastestMCP.read_resource(server_name, "memo://child/users/42")
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

    assert_scalar_tool_result(
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        payload: %{"name" => "calc", "arguments" => %{}}
      }),
      1
    )

    assert_scalar_tool_result(
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        payload: %{
          "name" => "calc",
          "arguments" => %{},
          "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
        }
      }),
      1
    )

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

    assert_scalar_tool_result(
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        payload: %{
          "name" => "calc",
          "arguments" => %{},
          "_meta" => %{"vendor" => %{"version" => "1.0.0", "stable" => true}}
        }
      }),
      2
    )

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
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })

    assert %{
             resourceTemplates: [
               %{
                 "uriTemplate" => "memo://users/{id}",
                 "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/templates/list",
               transport: :stdio
             })
  end

  defp assert_scalar_tool_result(result, expected) do
    assert %{"content" => [%{"type" => "text", "text" => encoded}]} = result
    refute Map.has_key?(result, "structuredContent")
    assert JSON.decode!(encoded) == expected
  end
end
