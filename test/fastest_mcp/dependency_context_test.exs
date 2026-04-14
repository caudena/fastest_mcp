defmodule FastestMCP.DependencyContextTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context

  test "request-scoped dependencies resolve once, expose server helpers, and clean up after sync calls" do
    parent = self()
    server_name = "deps-sync-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_dependency(:multiplier, fn _ctx ->
        Agent.update(counter, &(&1 + 1))

        {:ok, 10,
         fn value, cleanup_ctx ->
           send(parent, {:cleanup, value, cleanup_ctx.server_name})
         end}
      end)
      |> FastestMCP.add_tool("compute", fn %{"value" => value}, ctx ->
        send(
          parent,
          {:tool_ctx, Context.server(ctx).name, is_pid(Context.task_store(ctx)),
           Enum.sort(Context.dependencies(ctx))}
        )

        multiplier_a = Context.dependency(ctx, :multiplier)
        multiplier_b = Context.dependency(ctx, "multiplier")
        value * div(multiplier_a + multiplier_b, 2)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert 50 == FastestMCP.call_tool(server_name, "compute", %{"value" => 5})

    assert_receive {:tool_ctx, ^server_name, true, ["multiplier"]}, 1_000
    assert_receive {:cleanup, 10, ^server_name}, 1_000
    assert Agent.get(counter, & &1) == 1
  end

  test "background tasks resolve dependencies once and run cleanup after completion" do
    parent = self()
    server_name = "deps-task-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_dependency("connection", fn _ctx ->
        Agent.update(counter, &(&1 + 1))

        {:ok, "connection",
         fn value ->
           send(parent, {:cleanup, value})
         end}
      end)
      |> FastestMCP.add_tool(
        "use_connection",
        fn %{"value" => value}, ctx ->
          first = Context.dependency(ctx, :connection)
          second = Context.dependency(ctx, "connection")

          send(
            parent,
            {:task_ctx, Context.is_background_task(ctx), Context.server(ctx).name,
             is_pid(Context.task_store(ctx)), first == second}
          )

          %{"result" => "#{value}:#{first}"}
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    task = FastestMCP.call_tool(server_name, "use_connection", %{"value" => "ok"}, task: true)
    assert %BackgroundTask{} = task

    assert %{"result" => "ok:connection"} = FastestMCP.await_task(task, 1_000)
    assert_receive {:task_ctx, true, ^server_name, true, true}, 1_000
    assert_receive {:cleanup, "connection"}, 1_000
    assert Agent.get(counter, & &1) == 1
  end

  test "background prompts and resources can use context server/runtime helpers" do
    server_name = "deps-components-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt(
        "describe",
        fn %{"topic" => topic}, ctx ->
          "Prompt from #{Context.server(ctx).name} about #{topic}"
        end,
        task: true
      )
      |> FastestMCP.add_resource(
        "file://data.txt",
        fn _args, ctx ->
          %{"server" => Context.server(ctx).name, "task_store" => is_pid(Context.task_store(ctx))}
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    prompt_task =
      FastestMCP.render_prompt(server_name, "describe", %{"topic" => "tasks"}, task: true)

    resource_task = FastestMCP.read_resource(server_name, "file://data.txt", task: true)

    assert %{
             messages: [
               %{role: "user", content: "Prompt from " <> ^server_name <> " about tasks"}
             ]
           } = FastestMCP.await_task(prompt_task, 1_000)

    assert %{"server" => ^server_name, "task_store" => true} =
             FastestMCP.await_task(resource_task, 1_000)
  end
end
