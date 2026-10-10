defmodule FastestMCP.ClientTaskTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Interact

  test "remote task handles cache terminal status and final result" do
    server_name = "client-task-cache-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{value: value} end,
      task: [mode: :optional, poll_interval_ms: 50]
    )
    |> start_server!()

    client = connect_client!(server_name)

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "echo"} =
             task = Client.call_tool_task!(client, "echo", %{"value" => "cached"})

    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait!(task)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.status!(task)
    assert_tool_result(RemoteTask.result!(task), task_id, %{"value" => "cached"})

    assert :ok = FastestMCP.stop_server(server_name)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait!(task)
    assert_tool_result(RemoteTask.result!(task), task_id, %{"value" => "cached"})
  end

  test "remote task handles retry tasks/result after transient request failures" do
    parent = self()
    server_name = "client-task-retry-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "slow",
      fn _args, _ctx ->
        send(parent, {:slow_started, self()})

        receive do
          :release -> %{ok: true}
        end
      end,
      task: true
    )
    |> start_server!()

    client = connect_client!(server_name)

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool_task!(client, "slow", %{}, task: true)

    timeout_error =
      assert_raise FastestMCP.Error, fn ->
        RemoteTask.result!(task, timeout_ms: 1)
      end

    assert timeout_error.code == :timeout
    assert_receive {:slow_started, slow}, 1_000
    send(slow, :release)
    assert %{"taskId" => _, "status" => "completed"} = RemoteTask.wait!(task, timeout_ms: 2_000)

    assert_tool_result(
      RemoteTask.result!(task, timeout_ms: 2_000),
      task_id,
      %{"ok" => true}
    )
  end

  @tag :capture_log
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

    start_server!(server)

    client =
      connect_client!(server_name,
        session_stream: true
      )

    assert %RemoteTask{task_id: task_one_id} =
             task_one = Client.call_tool_task!(client, "wait", %{"label" => "one"}, task: true)

    assert %RemoteTask{task_id: task_two_id} =
             task_two = Client.call_tool_task!(client, "wait", %{"label" => "two"}, task: true)

    assert_receive {:entered_task, "one", pid_one}, 1_000
    assert_receive {:entered_task, "two", _pid_two}, 1_000

    RemoteTask.on_status_change!(task_one, fn _status ->
      raise "callback exploded"
    end)

    RemoteTask.on_status_change!(task_one, fn status ->
      send(parent, {:task_callback, "one", status["taskId"], status["status"]})
    end)

    RemoteTask.on_status_change!(task_two, fn status ->
      send(parent, {:task_callback, "two", status["taskId"], status["status"]})
    end)

    send(pid_one, :release)

    assert_receive {:task_callback, "one", ^task_one_id, "completed"}, 2_000
    refute_receive {:task_callback, "two", ^task_one_id, _}, 250
    refute_receive {:task_callback, "two", ^task_two_id, "completed"}, 250

    assert %{"taskId" => ^task_two_id, "status" => "cancelled"} = RemoteTask.cancel!(task_two)
    assert_receive {:task_callback, "two", ^task_two_id, "cancelled"}, 2_000

    assert %{"taskId" => ^task_one_id, "status" => "completed"} = RemoteTask.wait!(task_one)
    assert %{"taskId" => ^task_two_id, "status" => "cancelled"} = RemoteTask.wait!(task_two)
  end

  test "remote task augmentation is limited to tools/call" do
    server_name = "client-task-kinds-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{value: value} end,
      task: true
    )
    |> FastestMCP.add_prompt("draft", fn _args, _ctx -> "hello from prompt" end, task: true)
    |> FastestMCP.add_resource("memo://config", fn _args, _ctx -> %{env: "dev"} end, task: true)
    |> start_server!()

    client = connect_client!(server_name)

    assert %RemoteTask{kind: :tool, task_id: task_id} =
             tool_task =
             Client.call_tool_task!(client, "echo", %{"value" => "hi"}, task: true)

    assert_tool_result(RemoteTask.result!(tool_task), task_id, %{"value" => "hi"})

    assert %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "hello from prompt"}
               }
             ]
           } = Client.render_prompt!(client, "draft", %{})

    assert %{"env" => "dev"} = read_json!(client, "memo://config")
  end

  test "tasks/result relays elicitation over HTTP without the sendInput shortcut" do
    parent = self()
    server_name = "client-task-relay-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    client =
      connect_client!(server_name,
        session_stream: false,
        elicitation_handler: fn message, params ->
          send(parent, {:elicitation_handler_called, message, params})
          {:accept, %{"value" => "Alice"}}
        end
      )

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool_task!(client, "ask_name", %{}, task: true)

    result_task = Task.async(fn -> RemoteTask.result!(task) end)

    assert_receive {:elicitation_handler_called, "What is your name?", _params}, 2_000
    assert Client.info!(client).session_stream_open?

    assert_tool_result(Task.await(result_task, 6_000), task_id, %{"name" => "Alice"})
    assert_tool_result(RemoteTask.result!(task), task_id, %{"name" => "Alice"})
  end

  test "a 2025-11-25 task asks for roots, a ping, and a URL elicitation through tasks/result" do
    parent = self()
    server_name = unique_name("client-task-requests")

    # Each handler asks once the tools/call response has closed its stream.
    after_go = fn ask ->
      fn _args, ctx ->
        send(parent, {:started, self()})

        receive do
          :go -> ask.(ctx)
        end
      end
    end

    FastestMCP.server(server_name, url_elicitation_allowed_hosts: ["notes.example.com"])
    |> FastestMCP.add_auth(fn _input, _ctx -> {:ok, %{principal: %{"sub" => "42"}}} end)
    |> FastestMCP.add_tool(
      "roots",
      after_go.(&%{roots: Enum.map(Context.list_roots(&1), fn root -> root.uri end)}),
      task: true
    )
    |> FastestMCP.add_tool("ping", after_go.(&%{ping: inspect(Context.ping_peer(&1))}),
      task: true
    )
    |> FastestMCP.add_tool(
      "url",
      after_go.(fn ctx ->
        {:ok, %{url: url}} = Interact.url(ctx, "Connect", "https://notes.example.com/connect")
        %{url: url}
      end),
      task: true
    )
    |> start_server!()

    for session_stream <- [false, true] do
      client =
        connect_client!(server_name,
          session_stream: session_stream,
          roots: [%{uri: "file:///work", name: "Work"}],
          url_elicitation_handler: fn _request -> :accept end
        )

      for {tool, expected} <- [
            {"roots", %{"roots" => ["file:///work"]}},
            {"ping", %{"ping" => ":ok"}},
            {"url", %{"url" => "https://notes.example.com/connect"}}
          ] do
        task = Client.call_tool_task!(client, tool, %{}, task: true)
        assert_receive {:started, handler}
        send(handler, :go)
        assert RemoteTask.result!(task).structured_content == expected
      end
    end
  end

  test "call_tool_task/4 asks for the TTL that task: [ttl_ms: ms] names" do
    server_name = unique_name("client-task-ttl")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn _args, _ctx -> %{ok: true} end, task: true)
    |> start_server!()

    client = connect_client!(server_name)
    task = Client.call_tool_task!(client, "echo", %{}, task: [ttl_ms: 30_000])

    assert RemoteTask.fetch!(task)["ttl"] == 30_000
    assert RemoteTask.result!(task).structured_content == %{"ok" => true}
  end

  defp assert_tool_result(result, task_id, structured_content) do
    assert %{
             "content" => [%{"type" => "text", "text" => text}],
             "structuredContent" => ^structured_content,
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
             }
           } = result.raw

    assert JSON.decode!(text) == structured_content
  end

  defp connect_client!(server_name, opts \\ []) do
    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    connect!(url, Keyword.put_new(opts, :protocol_version, "2025-11-25"))
  end

  # The JSON value of a resource's one text content.
  defp read_json!(client, uri, opts \\ []) do
    assert %{"contents" => [%{"text" => text}]} = Client.read_resource!(client, uri, opts)
    JSON.decode!(text)
  end
end
