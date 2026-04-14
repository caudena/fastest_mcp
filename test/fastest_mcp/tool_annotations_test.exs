defmodule FastestMCP.ToolAnnotationsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "tool annotations are preserved in direct metadata and transport output" do
    server_name = "tool-annotations-" <> Integer.to_string(System.unique_integer([:positive]))

    annotations = %{
      title: "Echo Tool",
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
        annotations: annotations,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [tool] = FastestMCP.list_tools(server_name)
    assert tool.annotations == Map.new(annotations)
    assert tool.execution == %{taskSupport: "optional"}

    assert %{
             tools: [
               %{
                 "name" => "echo",
                 "annotations" => %{
                   "title" => "Echo Tool",
                   "readOnlyHint" => true,
                   "openWorldHint" => false,
                   "destructiveHint" => false
                 },
                 "execution" => %{taskSupport: "optional"}
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })
  end

  test "tool annotations must be maps" do
    assert_raise ArgumentError, ~r/component annotations must be a map/, fn ->
      FastestMCP.server("bad-annotations")
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end, annotations: [:bad])
    end
  end

  test "transport metadata emits fastestmcp _meta and strips internal fastestmcp fields" do
    server_name = "tool-meta-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
        tags: ["utility", "math"],
        version: "2.0.0",
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             tools: [
               %{
                 "name" => "echo",
                 "_meta" => %{
                   "vendor" => %{"stable" => true},
                   "fastestmcp" => %{
                     "hint" => "keep",
                     "tags" => ["math", "utility"],
                     "version" => "2.0.0"
                   }
                 }
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })
  end

  test "connected clients preserve tool _meta from tools/list" do
    server_name = "tool-meta-client-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
        tags: ["utility", "math"],
        version: "2.0.0",
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "tool-meta-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Process.alive?(bandit), do: Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end)

    assert %{
             items: [
               %{
                 "name" => "echo",
                 "_meta" => %{
                   "vendor" => %{"stable" => true},
                   "fastestmcp" => %{
                     "hint" => "keep",
                     "tags" => ["math", "utility"],
                     "version" => "2.0.0"
                   }
                 }
               }
             ],
             next_cursor: nil
           } = Client.list_tools(client)
  end

  test "resource metadata emits execution and fastestmcp _meta consistently" do
    server_name = "resource-meta-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("memo://report", fn _arguments, _ctx -> %{ok: true} end,
        tags: ["utility", "docs"],
        version: "2.0.0",
        task: true,
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )
      |> FastestMCP.add_resource("memo://sync", fn _arguments, _ctx -> %{ok: true} end,
        task: false
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn arguments, _ctx -> arguments end,
        tags: ["utility", "docs"],
        version: "2.0.0",
        task: true,
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )
      |> FastestMCP.add_resource_template(
        "memo://sync/{id}",
        fn arguments, _ctx -> arguments end,
        task: false
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{resources: resources, resourceTemplates: templates} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })

    report = Enum.find(resources, &(&1["uri"] == "memo://report"))
    sync = Enum.find(resources, &(&1["uri"] == "memo://sync"))
    users = Enum.find(templates, &(&1["uriTemplate"] == "memo://users/{id}"))
    sync_template = Enum.find(templates, &(&1["uriTemplate"] == "memo://sync/{id}"))

    assert report["execution"] == %{taskSupport: "optional"}
    refute Map.has_key?(sync, "execution")

    assert report["_meta"] == %{
             "vendor" => %{"stable" => true},
             "fastestmcp" => %{
               "hint" => "keep",
               "tags" => ["docs", "utility"],
               "version" => "2.0.0"
             }
           }

    assert users["execution"] == %{taskSupport: "optional"}
    refute Map.has_key?(sync_template, "execution")

    assert users["_meta"] == %{
             "vendor" => %{"stable" => true},
             "fastestmcp" => %{
               "hint" => "keep",
               "tags" => ["docs", "utility"],
               "version" => "2.0.0"
             }
           }
  end
end
