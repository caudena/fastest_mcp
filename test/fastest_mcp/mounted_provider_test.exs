defmodule FastestMCP.MountedProviderTest do
  use ExUnit.Case, async: false

  test "mounted servers expose namespaced tools, resources, prompts, and child middleware" do
    test_pid = self()
    parent_name = "mounted-parent-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-server")
      |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end)
      |> FastestMCP.add_resource("data://config", fn _args, _ctx -> "config data" end)
      |> FastestMCP.add_prompt("child_prompt", fn _args, _ctx -> "Hello from child!" end)
      |> FastestMCP.add_middleware(fn operation, next ->
        send(test_pid, {:child_middleware, :before, operation.method, operation.target})
        result = next.(operation)
        send(test_pid, {:child_middleware, :after, operation.method, operation.target})
        result
      end)

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert [%{name: "child_greet"}] = FastestMCP.list_tools(parent_name)

    assert "Hello, World!" ==
             FastestMCP.call_tool(parent_name, "child_greet", %{"name" => "World"})

    assert_receive {:child_middleware, :before, "tools/call", "greet"}, 1_000
    assert_receive {:child_middleware, :after, "tools/call", "greet"}, 1_000

    assert "config data" == FastestMCP.read_resource(parent_name, "data://child/config")

    assert %{messages: [%{role: "user", content: "Hello from child!"}]} ==
             FastestMCP.render_prompt(parent_name, "child_child_prompt", %{})
  end

  test "middleware runs at parent, child, and grandchild levels for mounted components" do
    test_pid = self()
    parent_name = "mounted-three-levels-" <> Integer.to_string(System.unique_integer([:positive]))

    grandchild =
      FastestMCP.server("grandchild")
      |> FastestMCP.add_tool("compute", fn %{"x" => x}, _ctx ->
        send(test_pid, "grandchild:tool")
        x * 2
      end)
      |> FastestMCP.add_resource("data://value", fn _args, _ctx ->
        send(test_pid, "grandchild:resource")
        "result"
      end)
      |> FastestMCP.add_resource_template("item://{id}", fn %{"id" => id}, _ctx ->
        send(test_pid, "grandchild:template")
        "item-#{id}"
      end)
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx ->
        send(test_pid, "grandchild:prompt")
        "Hello, #{name}!"
      end)
      |> FastestMCP.add_middleware(trace_middleware("grandchild", test_pid))

    child =
      FastestMCP.server("child")
      |> FastestMCP.mount(grandchild, namespace: "gc")
      |> FastestMCP.add_middleware(trace_middleware("child", test_pid))

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "c")
      |> FastestMCP.add_middleware(trace_middleware("parent", test_pid))

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert 10 == FastestMCP.call_tool(parent_name, "c_gc_compute", %{"x" => 5})

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:tool",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert "result" == FastestMCP.read_resource(parent_name, "data://c/gc/value")

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:resource",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert "item-42" == FastestMCP.read_resource(parent_name, "item://c/gc/42")

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:template",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert %{messages: [%{role: "user", content: "Hello, World!"}]} ==
             FastestMCP.render_prompt(parent_name, "c_gc_greet", %{"name" => "World"})

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:prompt",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])
  end

  test "mounted resource templates preserve query params and middleware order" do
    test_pid = self()
    parent_name = "mounted-query-" <> Integer.to_string(System.unique_integer([:positive]))

    grandchild =
      FastestMCP.server("grandchild-query")
      |> FastestMCP.add_resource_template(
        "item://{id}{?format}",
        fn %{"id" => id, "format" => format}, _ctx ->
          send(test_pid, "grandchild:query-template")
          "#{id}:#{format}"
        end
      )
      |> FastestMCP.add_middleware(trace_middleware("grandchild", test_pid))

    child =
      FastestMCP.server("child-query")
      |> FastestMCP.mount(grandchild, namespace: "gc")
      |> FastestMCP.add_middleware(trace_middleware("child", test_pid))

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "c")
      |> FastestMCP.add_middleware(trace_middleware("parent", test_pid))

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert "42:json" == FastestMCP.read_resource(parent_name, "item://c/gc/42?format=json")

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:query-template",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])
  end

  test "local components can override mounted tools with the same name" do
    parent_name =
      "mounted-local-override-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-server")
      |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Child says hi, #{name}" end)

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child)
      |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Parent override, #{name}" end)

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert [%{name: "greet"}, %{name: "greet"}] = FastestMCP.list_tools(parent_name)

    assert "Parent override, World" ==
             FastestMCP.call_tool(parent_name, "greet", %{"name" => "World"})
  end

  defp trace_middleware(label, pid) do
    fn operation, next ->
      send(pid, "#{label}:before")
      result = next.(operation)
      send(pid, "#{label}:after")
      result
    end
  end

  defp assert_trace_order(expected) do
    received =
      Enum.map(expected, fn _ ->
        receive do
          value -> value
        after
          1_000 -> flunk("expected trace message")
        end
      end)

    assert expected == received
  end
end
