defmodule FastestMCP.VersioningTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Apps
  alias FastestMCP.Error
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Providers.Local
  alias FastestMCP.TaskBackend.Memory
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  defmodule DescriptorlessTaskBackend do
    @moduledoc false
    # Keeps tasks without the descriptor of the component that ran them.
    @behaviour FastestMCP.TaskBackend

    @impl true
    defdelegate init(opts), to: Memory

    @impl true
    def put_task(table, task), do: Memory.put_task(table, %{task | component_descriptor: nil})

    @impl true
    defdelegate fetch_task(table, task_id), to: Memory

    @impl true
    defdelegate delete_task(table, task_id), to: Memory

    @impl true
    defdelegate list_tasks(table), to: Memory
  end

  test "highest version wins by default and exact versions remain callable" do
    server_name = "versioning-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0")
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0")
    |> start_server!()

    assert 2 == FastestMCP.call_tool!(server_name, "calc", %{})
    assert 1 == FastestMCP.call_tool!(server_name, "calc", %{}, version: "1.0")
    assert 2 == FastestMCP.call_tool!(server_name, "calc", %{}, version: "2.0")
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

    FastestMCP.server(server_name, transforms: [transform])
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert {:ok,
            %Operation{result: 1, component: %{name: "calc", version: "1.0.0", enabled: true}}} =
             OperationPipeline.invoke(server_name, :tool, "calc", %{}, [])

    assert_receive {:transformed, "2.0.0"}
    assert_receive {:transformed, "1.0.0"}
    refute_receive {:transformed, _version}
  end

  test "unversioned resolution falls back past unauthorized tools and templates" do
    server_name = "authorization-version-fallback-#{System.unique_integer([:positive])}"

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
    |> start_server!()

    assert "tool_v1" == FastestMCP.call_tool!(server_name, "secure", %{})
    assert "template_v1:42" == FastestMCP.read_resource!(server_name, "secure://items/42")

    tool_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_name, "secure", %{}, version: "2.0.0")
      end

    assert tool_error.code == :forbidden

    template_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource!(server_name, "secure://items/42", version: "2.0.0")
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

    start_server!(server)

    :ok =
      FastestMCP.disable_components!(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    assert {:ok,
            %Operation{
              result: "resource_v1",
              component: %{uri: "memo://config", version: "1.0.0"}
            }} = OperationPipeline.invoke(server_name, :resource, "memo://config", %{}, [])

    assert {:ok,
            %Operation{
              result: "template_v1:42",
              component: %{uri_template: "memo://users/{id}", version: "1.0.0"}
            }} = OperationPipeline.invoke(server_name, :resource, "memo://users/42", %{}, [])
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

    FastestMCP.server(server_name, transforms: [disable_v2])
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    assert 1 == FastestMCP.call_tool!(server_name, "child_calc", %{})
    assert "resource_v1" == FastestMCP.read_resource!(server_name, "memo://child/config")

    assert "template_v1:42" ==
             FastestMCP.read_resource!(server_name, "memo://child/users/42")
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

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")
    |> start_server!()

    :ok =
      FastestMCP.disable_components!(server_name,
        names: ["calc"],
        version: %{eq: "2.0.0"},
        components: [:tool]
      )

    assert [{"calc", "1.0.0"}] ==
             FastestMCP.list_tools!(server_name)
             |> Enum.map(&{&1.name, &1.version})

    assert 1 == FastestMCP.call_tool!(server_name, "calc", %{})

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.call_tool!(server_name, "calc", %{}, version: "2.0.0")
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

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
    |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")
    |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "1.0.0"} end,
      version: "1.0.0"
    )
    |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{version: "2.0.0"} end,
      version: "2.0.0"
    )
    |> start_server!()

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
    |> start_server!()

    :ok =
      FastestMCP.disable_components!(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    assert [{"memo://config", "1.0.0"}] ==
             FastestMCP.list_resources!(server_name)
             |> Enum.map(&{&1.uri, &1.version})

    assert [{"memo://users/{id}", "1.0.0"}] ==
             FastestMCP.list_resource_templates!(server_name)
             |> Enum.map(&{&1.uri_template, &1.version})

    assert %{version: "1.0.0"} == FastestMCP.read_resource!(server_name, "memo://config")

    assert %{id: "42", version: "1.0.0"} ==
             FastestMCP.read_resource!(server_name, "memo://users/42")

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.read_resource!(server_name, "memo://config", version: "2.0.0")
    end

    assert_raise Error, ~r/disabled/, fn ->
      FastestMCP.read_resource!(server_name, "memo://users/42", version: "2.0.0")
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

  # Version 2.0.0 is forbidden to every caller. Version 1.0.0 is an MCP Apps
  # tool, so its descriptor requires a content fallback the empty result
  # lacks: the fallback error shows which descriptor serialized the result.
  test "tool results serialize with the highest version the caller may use" do
    server_name = unique_name("descriptor")

    FastestMCP.server(server_name, extensions: %{Extensions.apps() => %{}})
    |> FastestMCP.add_tool("report", fn _args, _ctx -> ToolResult.from(%{content: []}) end,
      version: "1.0.0",
      task: true,
      meta: Apps.tool_meta("ui://report/view")
    )
    |> FastestMCP.add_tool("report", fn _args, _ctx -> "forbidden" end,
      version: "2.0.0",
      task: true,
      auth: fn _context -> false end
    )
    |> start_server!(task_backend: {DescriptorlessTaskBackend, []})

    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name)
    call = %{"name" => "report", "arguments" => %{}}

    http = ProtocolTest.http_request(server_name, session_id, 2, "tools/call", call)
    assert JSON.decode!(http.resp_body)["error"]["message"] =~ "non-empty content fallback"

    stdio = ProtocolTest.stdio_request(server_name, connection_id, 2, "tools/call", call)
    assert stdio["error"]["message"] =~ "non-empty content fallback"

    # The task store lost the descriptor, so the result resolves it again.
    task_call = Map.put(call, "task", %{"ttl" => 30_000})
    created = ProtocolTest.http_request(server_name, session_id, 3, "tools/call", task_call)
    %{"result" => %{"task" => %{"taskId" => task_id}}} = JSON.decode!(created.resp_body)
    FastestMCP.await_task!(server_name, task_id, 1_000, session_id: session_id)

    result =
      ProtocolTest.http_request(server_name, session_id, 4, "tasks/result", %{
        "taskId" => task_id
      })

    assert JSON.decode!(result.resp_body)["error"]["message"] =~ "non-empty content fallback"
  end

  defp assert_scalar_tool_result(result, expected) do
    assert %{"content" => [%{"type" => "text", "text" => encoded}]} = result
    refute Map.has_key?(result, "structuredContent")
    assert JSON.decode!(encoded) == expected
  end
end
