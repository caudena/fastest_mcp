defmodule FastestMCP.ToolAnnotationsTest do
  use FastestMCP.Case, async: true

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

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
      annotations: annotations,
      task: true
    )
    |> start_server!()

    [tool] = FastestMCP.list_tools!(server_name)
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
                 "execution" => %{"taskSupport" => "optional"},
                 "_meta" => %{"fastestmcp" => %{"tags" => []}}
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

  test "tool names follow MCP's naming rules when you define them" do
    add = fn name -> FastestMCP.add_tool(FastestMCP.server("tool-names"), name, fn -> :ok end) end

    for name <- ["search notes", "notes/search", "", String.duplicate("a", 129), "búsqueda"] do
      assert_raise ArgumentError, ~r/tool name must be 1 to 128 letters, digits/, fn ->
        add.(name)
      end
    end

    for name <- ["getUser", "DATA_EXPORT_v2", "admin.tools.list", "search-notes"] do
      assert [%{name: ^name}] = add.(name).tools
    end

    assert [_tool] = add.(String.duplicate("a", 128)).tools

    assert_raise ArgumentError, ~r/tool name/, fn ->
      FastestMCP.Components.Tool.new("search notes", fn -> :ok end)
    end

    assert_raise ArgumentError, ~r/tool name/, fn ->
      FastestMCP.Providers.Local.add_tool(FastestMCP.Providers.Local.new(), "a b", fn -> :ok end)
    end

    # Composed names stay valid: a namespace and a rename use the same rules.
    assert_raise ArgumentError, ~r/namespace must be letters, digits/, fn ->
      FastestMCP.ProviderTransforms.Namespace.new("my notes")
    end

    assert_raise ArgumentError, ~r/namespace/, fn ->
      FastestMCP.mount(FastestMCP.server("parent"), FastestMCP.server("child"), namespace: "a/b")
    end

    assert_raise ArgumentError, ~r/tool name/, fn ->
      FastestMCP.ProviderTransforms.ToolTransform.new(%{"search" => %{name: "find notes"}})
    end
  end

  test "resource annotations hold the values MCP defines" do
    server =
      FastestMCP.server("resource-annotations")
      |> FastestMCP.add_resource("notes://help", fn -> "help" end,
        annotations: %{
          audience: ["user", "assistant"],
          priority: 0.5,
          lastModified: "2025-01-12T15:00:58Z",
          cacheable: true
        }
      )
      |> FastestMCP.add_resource_template("notes://{id}", fn _args -> "note" end,
        annotations: %{"priority" => 1, "lastModified" => ~U[2025-01-12 15:00:58Z]}
      )

    assert [_resource] = server.resources

    for {annotations, message} <- [
          {%{audience: ["admin"]},
           ~r/annotation audience must be a list of "user" and "assistant"/},
          {%{audience: "user"}, ~r/annotation audience/},
          {%{priority: 1.5}, ~r/annotation priority must be a number from 0 to 1/},
          {%{"priority" => "high"}, ~r/annotation priority/},
          {%{lastModified: "yesterday"}, ~r/annotation lastModified must be an ISO 8601/}
        ] do
      assert_raise ArgumentError, message, fn ->
        FastestMCP.add_resource(server, "notes://bad", fn -> "bad" end, annotations: annotations)
      end

      assert_raise ArgumentError, message, fn ->
        FastestMCP.add_resource_template(server, "bad://{id}", fn _args -> "bad" end,
          annotations: annotations
        )
      end
    end
  end

  test "transport metadata emits fastestmcp _meta and strips internal fastestmcp fields" do
    server_name = "tool-meta-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
      tags: ["utility", "math"],
      version: "2.0.0",
      meta: %{
        "vendor" => %{"stable" => true},
        "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
      }
    )
    |> start_server!()

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

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
      tags: ["utility", "math"],
      version: "2.0.0",
      meta: %{
        "vendor" => %{"stable" => true},
        "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
      }
    )
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(url,
        client_info: %{"name" => "tool-meta-client", "version" => "1.0.0"}
      )

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
           } = Client.list_tools!(client)
  end

  test "resource metadata emits execution and fastestmcp _meta consistently" do
    server_name = "resource-meta-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> FastestMCP.add_resource("memo://sync", fn _arguments, _ctx -> %{ok: true} end, task: false)
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
    |> start_server!()

    assert %{resources: resources} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })

    assert %{resourceTemplates: templates} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/templates/list",
               transport: :stdio
             })

    report = Enum.find(resources, &(&1["uri"] == "memo://report"))
    sync = Enum.find(resources, &(&1["uri"] == "memo://sync"))
    users = Enum.find(templates, &(&1["uriTemplate"] == "memo://users/{id}"))
    sync_template = Enum.find(templates, &(&1["uriTemplate"] == "memo://sync/{id}"))

    refute Map.has_key?(report, "execution")
    refute Map.has_key?(sync, "execution")

    assert report["_meta"] == %{
             "vendor" => %{"stable" => true},
             "fastestmcp" => %{
               "hint" => "keep",
               "tags" => ["docs", "utility"],
               "version" => "2.0.0"
             }
           }

    refute Map.has_key?(users, "execution")
    refute Map.has_key?(users, "parameters")
    refute Map.has_key?(sync_template, "execution")

    assert %{
             "vendor" => %{"stable" => true},
             "fastestmcp" => %{
               "hint" => "keep",
               "parameters" => %{},
               "tags" => ["docs", "utility"],
               "version" => "2.0.0"
             }
           } = users["_meta"]
  end
end
