defmodule FastestMCP.ClientTaskTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted

  test "remote task handles cache terminal status and final result" do
    server_name = "client-task-cache-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{value: value} end,
        task: [mode: :optional, poll_interval_ms: 50]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit = start_http_transport!(server_name)
    client = connect_client!(bandit)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "echo"} =
             task = Client.call_tool(client, "echo", %{"value" => "cached"}, task: true)

    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait(task)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.status(task)
    assert_tool_result(RemoteTask.result(task), task_id, %{"value" => "cached"})

    assert :ok = FastestMCP.stop_server(server_name)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait(task)
    assert_tool_result(RemoteTask.result(task), task_id, %{"value" => "cached"})
  end

  test "remote task handles retry tasks/result after transient request failures" do
    server_name = "client-task-retry-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "slow",
        fn _args, _ctx ->
          Process.sleep(150)
          %{ok: true}
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit = start_http_transport!(server_name)
    client = connect_client!(bandit)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool(client, "slow", %{}, task: true)

    timeout_error =
      assert_raise FastestMCP.Error, fn ->
        RemoteTask.result(task, timeout_ms: 1)
      end

    assert timeout_error.code == :timeout
    assert %{"taskId" => _, "status" => "completed"} = RemoteTask.wait(task, timeout_ms: 2_000)

    assert_tool_result(
      RemoteTask.result(task, timeout_ms: 2_000),
      task_id,
      %{"ok" => true}
    )
  end

  test "task handle callbacks fan out, survive callback failures, and stay isolated per task" do
    parent = self()

    server_name =
      "client-task-callbacks-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn %{"label" => label}, _ctx ->
          send(parent, {:entered_task, label, self()})

          receive do
            :release -> %{label: label}
          after
            5_000 -> %{timed_out: label}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit = start_http_transport!(server_name)

    client =
      connect_client!(bandit,
        session_stream: true
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{task_id: task_one_id} =
             task_one = Client.call_tool(client, "wait", %{"label" => "one"}, task: true)

    assert %RemoteTask{task_id: task_two_id} =
             task_two = Client.call_tool(client, "wait", %{"label" => "two"}, task: true)

    assert_receive {:entered_task, "one", pid_one}, 1_000
    assert_receive {:entered_task, "two", _pid_two}, 1_000

    RemoteTask.on_status_change(task_one, fn _status ->
      raise "callback exploded"
    end)

    RemoteTask.on_status_change(task_one, fn status ->
      send(parent, {:task_callback, "one", status["taskId"], status["status"]})
    end)

    RemoteTask.on_status_change(task_two, fn status ->
      send(parent, {:task_callback, "two", status["taskId"], status["status"]})
    end)

    send(pid_one, :release)

    assert_receive {:task_callback, "one", ^task_one_id, "completed"}, 2_000
    refute_receive {:task_callback, "two", ^task_one_id, _}, 250
    refute_receive {:task_callback, "two", ^task_two_id, "completed"}, 250

    assert %{"taskId" => ^task_two_id, "status" => "cancelled"} = RemoteTask.cancel(task_two)
    assert_receive {:task_callback, "two", ^task_two_id, "cancelled"}, 2_000

    assert %{"taskId" => ^task_one_id, "status" => "completed"} = RemoteTask.wait(task_one)
    assert %{"taskId" => ^task_two_id, "status" => "cancelled"} = RemoteTask.wait(task_two)
  end

  test "remote task augmentation is limited to tools/call" do
    server_name = "client-task-kinds-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{value: value} end,
        task: true
      )
      |> FastestMCP.add_prompt("draft", fn _args, _ctx -> "hello from prompt" end, task: true)
      |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{env: "dev"} end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit = start_http_transport!(server_name)
    client = connect_client!(bandit)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{kind: :tool, task_id: task_id} =
             tool_task =
             Client.call_tool(client, "echo", %{"value" => "hi"}, task: true)

    assert_tool_result(RemoteTask.result(tool_task), task_id, %{"value" => "hi"})

    assert %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "hello from prompt"}
               }
             ]
           } = Client.render_prompt(client, "draft", %{})

    assert %{"env" => "dev"} = Client.read_resource(client, "memo://config")
  end

  test "tasks/result relays elicitation over HTTP without the sendInput shortcut" do
    parent = self()
    server_name = "client-task-relay-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _args, ctx ->
          case Context.elicit(ctx, "What is your name?", :string) do
            %Accepted{data: name} -> %{name: name}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit = start_http_transport!(server_name)

    client =
      connect_client!(bandit,
        session_stream: false,
        elicitation_handler: fn message, params ->
          send(parent, {:elicitation_handler_called, message, params})
          {:accept, %{"value" => "Alice"}}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool(client, "ask_name", %{}, task: true)

    result_task = Task.async(fn -> RemoteTask.result(task) end)

    assert_receive {:elicitation_handler_called, "What is your name?", _params}, 2_000
    assert Client.session_stream_open?(client)

    assert_tool_result(Task.await(result_task, 6_000), task_id, %{"name" => "Alice"})
    assert_tool_result(RemoteTask.result(task), task_id, %{"name" => "Alice"})
  end

  defp assert_tool_result(result, task_id, structured_content) do
    assert %{
             "content" => [%{"type" => "text", "text" => text}],
             "structuredContent" => ^structured_content,
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
             }
           } = result

    assert JSON.decode!(text) == structured_content
  end

  defp start_http_transport!(server_name) do
    start_supervised!(
      {Bandit,
       plug:
         {FastestMCP.Transport.HTTPApp,
          server_name: server_name,
          path: "/mcp",
          allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
       scheme: :http,
       port: 0}
    )
  end

  defp connect_client!(bandit, opts \\ []) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    Client.connect!("http://127.0.0.1:#{port}/mcp", opts)
  end
end
