defmodule FastestMCP.TaskMetaTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error
  alias FastestMCP.TaskMeta

  test "task-enabled direct calls stay synchronous unless task_meta is provided" do
    server_name = "task-meta-sync-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("double", fn %{"value" => value}, _ctx -> value * 2 end, task: true)
      |> FastestMCP.add_prompt("describe", fn %{"topic" => topic}, _ctx -> "topic:" <> topic end,
        task: true
      )
      |> FastestMCP.add_resource("data://status", fn _args, _ctx -> "ready" end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert 10 == FastestMCP.call_tool(server_name, "double", %{"value" => 5})

    assert %{
             messages: [%{role: "user", content: "topic:tasks"}]
           } == FastestMCP.render_prompt(server_name, "describe", %{"topic" => "tasks"})

    assert "ready" == FastestMCP.read_resource(server_name, "data://status")

    assert %BackgroundTask{} =
             FastestMCP.call_tool(server_name, "double", %{"value" => 5},
               task_meta: TaskMeta.new()
             )

    assert %BackgroundTask{} =
             FastestMCP.render_prompt(server_name, "describe", %{"topic" => "tasks"},
               task_meta: TaskMeta.new()
             )

    assert %BackgroundTask{} =
             FastestMCP.read_resource(server_name, "data://status", task_meta: TaskMeta.new())
  end

  test "task_meta propagates custom ttl through direct nested tool prompt and resource calls" do
    server_name = "task-meta-nested-" <> Integer.to_string(System.unique_integer([:positive]))
    ttl_ms = 45_000

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("inner_tool", fn %{"value" => value}, _ctx -> value * 2 end,
        task: true
      )
      |> FastestMCP.add_prompt(
        "inner_prompt",
        fn %{"topic" => topic}, _ctx -> "prompt:" <> topic end,
        task: true
      )
      |> FastestMCP.add_resource("data://inner", fn _args, _ctx -> "resource:ok" end, task: true)
      |> FastestMCP.add_resource_template(
        "item://{id}",
        fn %{"id" => id}, _ctx -> "item:" <> id end,
        task: true
      )
      |> FastestMCP.add_tool("outer", fn _args, _ctx ->
        task_meta = TaskMeta.new(ttl: ttl_ms)

        tool_task =
          FastestMCP.call_tool(server_name, "inner_tool", %{"value" => 7}, task_meta: task_meta)

        prompt_task =
          FastestMCP.render_prompt(server_name, "inner_prompt", %{"topic" => "nested"},
            task_meta: task_meta
          )

        resource_task =
          FastestMCP.read_resource(server_name, "data://inner", task_meta: task_meta)

        template_task =
          FastestMCP.read_resource(server_name, "item://42", task_meta: task_meta)

        %{
          tool: %{task_id: tool_task.task_id, ttl: tool_task.ttl_ms},
          prompt: %{task_id: prompt_task.task_id, ttl: prompt_task.ttl_ms},
          resource: %{task_id: resource_task.task_id, ttl: resource_task.ttl_ms},
          template: %{task_id: template_task.task_id, ttl: template_task.ttl_ms}
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result = FastestMCP.call_tool(server_name, "outer", %{}, session_id: "task-meta-session")

    for key <- [:tool, :prompt, :resource, :template] do
      assert result[key].ttl == ttl_ms

      assert %{ttl_ms: ^ttl_ms, session_id: "task-meta-session"} =
               FastestMCP.fetch_task(server_name, result[key].task_id,
                 session_id: "task-meta-session"
               )
    end

    assert 14 ==
             FastestMCP.await_task(server_name, result.tool.task_id, 1_000,
               session_id: "task-meta-session"
             )

    assert %{
             messages: [%{role: "user", content: "prompt:nested"}]
           } =
             FastestMCP.await_task(server_name, result.prompt.task_id, 1_000,
               session_id: "task-meta-session"
             )

    assert "resource:ok" ==
             FastestMCP.await_task(server_name, result.resource.task_id, 1_000,
               session_id: "task-meta-session"
             )

    assert "item:42" ==
             FastestMCP.await_task(server_name, result.template.task_id, 1_000,
               session_id: "task-meta-session"
             )
  end

  test "task_meta raises a not_found error for forbidden direct task execution" do
    server_name = "task-meta-forbidden-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sync_tool", fn _args, _ctx -> :ok end, task: false)
      |> FastestMCP.add_prompt("sync_prompt", fn _args, _ctx -> "ok" end, task: false)
      |> FastestMCP.add_resource("data://sync", fn _args, _ctx -> "ok" end, task: false)
      |> FastestMCP.add_resource_template("item://{id}", fn %{"id" => id}, _ctx -> id end,
        task: false
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tool_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "sync_tool", %{}, task_meta: TaskMeta.new())
      end

    prompt_error =
      assert_raise Error, fn ->
        FastestMCP.render_prompt(server_name, "sync_prompt", %{}, task_meta: TaskMeta.new())
      end

    resource_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "data://sync", task_meta: TaskMeta.new())
      end

    template_error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "item://42", task_meta: TaskMeta.new())
      end

    for error <- [tool_error, prompt_error, resource_error, template_error] do
      assert error.code == :not_found
      assert error.message =~ "does not support background task execution"
    end
  end

  test "task_meta accepts keyword and map input for ttl" do
    server_name = "task-meta-coerce-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    keyword_task =
      FastestMCP.call_tool(server_name, "echo", %{"value" => "keyword"}, task_meta: [ttl: 120])

    map_task =
      FastestMCP.call_tool(server_name, "echo", %{"value" => "map"}, task_meta: %{ttl: 140})

    assert keyword_task.ttl_ms == 120
    assert map_task.ttl_ms == 140

    assert "keyword" == FastestMCP.await_task(keyword_task, 1_000)
    assert "map" == FastestMCP.await_task(map_task, 1_000)
  end
end
