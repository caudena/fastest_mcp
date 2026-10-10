defmodule FastestMCP.MountedProviderTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Context

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

    FastestMCP.server(parent_name)
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    assert [%{name: "child_greet"}] = FastestMCP.list_tools!(parent_name)

    assert "Hello, World!" ==
             FastestMCP.call_tool!(parent_name, "child_greet", %{"name" => "World"})

    assert_receive {:child_middleware, :before, "tools/call", "greet"}, 1_000
    assert_receive {:child_middleware, :after, "tools/call", "greet"}, 1_000

    assert "config data" == FastestMCP.read_resource!(parent_name, "data://child/config")

    assert %{messages: [%{role: "user", content: %{type: "text", text: "Hello from child!"}}]} =
             FastestMCP.render_prompt!(parent_name, "child_child_prompt", %{})
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

    start_server!(parent)

    assert 10 == FastestMCP.call_tool!(parent_name, "c_gc_compute", %{"x" => 5})

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:tool",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert "result" == FastestMCP.read_resource!(parent_name, "data://c/gc/value")

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:resource",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert "item-42" == FastestMCP.read_resource!(parent_name, "item://c/gc/42")

    assert_trace_order([
      "parent:before",
      "child:before",
      "grandchild:before",
      "grandchild:template",
      "grandchild:after",
      "child:after",
      "parent:after"
    ])

    assert %{messages: [%{role: "user", content: %{type: "text", text: "Hello, World!"}}]} =
             FastestMCP.render_prompt!(parent_name, "c_gc_greet", %{"name" => "World"})

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

    start_server!(parent)

    assert "42:json" == FastestMCP.read_resource!(parent_name, "item://c/gc/42?format=json")

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

  test "mounted wildcard resource templates preserve the wildcard path" do
    parent_name =
      "mounted-wildcard-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-wildcard")
      |> FastestMCP.add_resource_template("files://{path*}", fn %{"path" => path}, _ctx ->
        "file:#{path}"
      end)

    FastestMCP.server(parent_name)
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    assert "file:alpha/beta/gamma.txt" ==
             FastestMCP.read_resource!(parent_name, "files://child/alpha/beta/gamma.txt")
  end

  test "self-mounts are rejected and mounted lifespans are visible to child handlers" do
    test_pid = self()
    parent_name = "mounted-lifespan-" <> Integer.to_string(System.unique_integer([:positive]))

    assert_raise ArgumentError, ~r/cannot mount/, fn ->
      server = FastestMCP.server("self-mounted")
      FastestMCP.mount(server, server)
    end

    assert_raise ArgumentError, ~r/unknown keys \[:prefix\]/, fn ->
      FastestMCP.mount(FastestMCP.server("mount-parent"), FastestMCP.server("mount-child"),
        prefix: "child"
      )
    end

    child =
      FastestMCP.server("lifespan-child")
      |> FastestMCP.add_lifespan(fn _server ->
        send(test_pid, :child_enter)
        {%{"scope" => "child"}, fn -> send(test_pid, :child_exit) end}
      end)
      |> FastestMCP.add_tool("scope", fn _args, ctx -> ctx.lifespan_context end)

    FastestMCP.server(parent_name)
    |> FastestMCP.add_lifespan(fn _server ->
      send(test_pid, :parent_enter)
      {%{"scope" => "parent"}, fn -> send(test_pid, :parent_exit) end}
    end)
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    assert_receive :parent_enter, 1_000
    assert_receive :child_enter, 1_000

    assert %{"scope" => "child"} == FastestMCP.call_tool!(parent_name, "child_scope", %{})

    assert :ok = FastestMCP.stop_server(parent_name)
    assert_receive :child_exit, 1_000
    assert_receive :parent_exit, 1_000
  end

  test "mounted handlers resolve their own server's dependencies over the parent's" do
    parent_name = unique_name("mounted-dependencies")
    dependency = &FastestMCP.Context.dependency/2

    grandchild =
      FastestMCP.server("dependency-grandchild")
      |> FastestMCP.add_dependency(:level, fn -> "grandchild" end)
      |> FastestMCP.add_tool("deps", fn _args, ctx ->
        %{level: dependency.(ctx, :level), child: dependency.(ctx, :child_only)}
      end)

    child =
      FastestMCP.server("dependency-child")
      |> FastestMCP.add_dependency(:level, fn -> "child" end)
      |> FastestMCP.add_dependency(:child_only, fn -> "child" end)
      # Runs in the handler's process before the grandchild's handler, in the
      # same request: the grandchild must still get its own value.
      |> FastestMCP.add_middleware(fn operation, next ->
        "child" = dependency.(operation.context, :level)
        next.(operation)
      end)
      |> FastestMCP.add_tool("deps", fn _args, ctx ->
        %{level: dependency.(ctx, :level), parent: dependency.(ctx, :parent_only)}
      end)
      |> FastestMCP.mount(grandchild, namespace: "grandchild")

    FastestMCP.server(parent_name)
    |> FastestMCP.add_dependency(:level, fn -> "parent" end)
    |> FastestMCP.add_dependency(:parent_only, fn -> "parent" end)
    |> FastestMCP.add_tool("deps", fn _args, ctx -> %{level: dependency.(ctx, :level)} end)
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    assert %{level: "parent"} == FastestMCP.call_tool!(parent_name, "deps")

    assert %{level: "child", parent: "parent"} ==
             FastestMCP.call_tool!(parent_name, "child_deps")

    assert %{level: "grandchild", child: "child"} ==
             FastestMCP.call_tool!(parent_name, "child_grandchild_deps")
  end

  test "mounted handlers use the session of the server the client called" do
    parent_name = unique_name("mounted-session")
    test_pid = self()

    # Each level's handler keeps a visit count in session state, logs it,
    # reports progress, sends a notification, and, for a client, asks for its
    # roots, which the session caches.
    visit = fn level ->
      fn _args, ctx ->
        visits = Context.get_state(ctx, :visits, 0) + 1
        :ok = Context.set_state(ctx, :visits, visits)
        client? = not is_nil(ctx.negotiated_protocol_version)

        %{
          visits: visits,
          session: ctx.session_id,
          log: inspect(Context.info(ctx, "#{level} visit #{visits}")),
          progress: inspect(Context.report_progress(ctx, visits, 10)),
          notification:
            inspect(Context.send_notification(ctx, "notifications/com.example/visited", %{})),
          roots: client? && ctx |> Context.list_roots() |> Enum.map(& &1.uri),
          cached_roots: client? && Enum.map(Context.cached_roots(ctx) || [], & &1.uri)
        }
      end
    end

    hide = fn _args, ctx ->
      :ok = Context.disable_components(ctx, names: ["visit"])
      "hidden"
    end

    grandchild =
      FastestMCP.server("session-grandchild")
      |> FastestMCP.add_tool("visit", visit.("grandchild"))
      |> FastestMCP.add_tool("hide", hide)

    child =
      FastestMCP.server("session-child")
      |> FastestMCP.add_tool("visit", visit.("child"))
      |> FastestMCP.mount(grandchild, namespace: "grandchild")

    FastestMCP.server(parent_name)
    |> FastestMCP.add_tool("visit", visit.("parent"))
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    client =
      connect!({:in_process, parent_name},
        protocol_version: "2025-11-25",
        roots: [%{uri: "file:///work", name: "Work"}],
        log_handler: &send(test_pid, {:log, &1["data"]}),
        notification_handler: &send(test_pid, {:notification, &1["method"]})
      )

    sessions =
      for {tool, visits, level} <- [
            {"visit", 1, "parent"},
            {"child_visit", 2, "child"},
            {"child_grandchild_visit", 3, "grandchild"}
          ] do
        result =
          Client.call_tool!(client, tool, %{},
            progress_handler: &send(test_pid, {:progress, &1["progress"]})
          )

        assert %{
                 "visits" => ^visits,
                 "log" => ":ok",
                 "progress" => ":ok",
                 "roots" => ["file:///work"],
                 "cached_roots" => ["file:///work"]
               } = result.structured_content

        assert result.structured_content["notification"] =~ "{:ok, "
        assert_receive {:log, message}
        assert message == "#{level} visit #{visits}"
        assert_receive {:progress, ^visits}
        assert_receive {:notification, "notifications/com.example/visited"}
        result.structured_content["session"]
      end

    # Every level sees the session of the client's connection.
    assert ["stdio-" <> _id = session_id, session_id, session_id] = sessions

    # A grandchild's handler hides a tool from this session only, by the name
    # the client sees.
    assert [%{"text" => "hidden"}] =
             Client.call_tool!(client, "child_grandchild_hide", %{}).content

    assert_receive {:notification, "notifications/tools/list_changed"}
    refute "visit" in Enum.map(Client.list_tools!(client).items, & &1["name"])
    assert "visit" in Enum.map(FastestMCP.list_tools!(parent_name), & &1.name)

    # In-process calls that name a session use that session at every level.
    for {tool, visits} <- [{"child_grandchild_visit", 1}, {"child_visit", 2}, {"visit", 3}] do
      assert %{visits: ^visits, session: "s1", log: ":ok"} =
               FastestMCP.call_tool!(parent_name, tool, %{}, session_id: "s1")
    end
  end

  test "local components can override mounted tools with the same name" do
    parent_name =
      "mounted-local-override-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-server")
      |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Child says hi, #{name}" end)

    FastestMCP.server(parent_name)
    |> FastestMCP.mount(child)
    |> FastestMCP.add_tool("greet", fn %{"name" => name}, _ctx -> "Parent override, #{name}" end)
    |> start_server!()

    # The name is listed once, as the call resolves it: the parent's own tool.
    assert [%{name: "greet"}] = FastestMCP.list_tools!(parent_name)

    assert "Parent override, World" ==
             FastestMCP.call_tool!(parent_name, "greet", %{"name" => "World"})
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
