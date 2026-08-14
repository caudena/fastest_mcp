defmodule FastestMCP.Tasks2026ExtensionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Schema
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  @modern_version "2026-07-28"
  @client_info %{"name" => "tasks-extension-test", "version" => "1.0.0"}

  test "notifications/tasks is a server notification with the Tasks wire schema" do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tasks",
      "params" => %{
        "taskId" => "task-1",
        "status" => "working",
        "createdAt" => "2026-08-14T00:00:00Z",
        "lastUpdatedAt" => "2026-08-14T00:00:00Z",
        "ttlMs" => 60_000
      }
    }

    assert Schema.protocol_supported?(
             @modern_version,
             :server_to_client,
             :notification,
             "notifications/tasks"
           )

    refute Schema.protocol_supported?(
             @modern_version,
             :client_to_server,
             :notification,
             "notifications/tasks"
           )

    assert {:ok, ^notification} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :notification,
               "notifications/tasks",
               notification
             )
  end

  test "HTTP and stdio reject task subscription filters without the Tasks capability" do
    server_name = unique_name("tasks-subscription-capability")
    start_server!(server_name, FastestMCP.server(server_name, extensions: tasks_extensions()))

    params = %{"notifications" => %{"taskIds" => ["task-1"]}}

    http_response =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "subscriptions/listen",
        params
      )

    assert %{"error" => %{"code" => -32_021}} = JSON.decode!(http_response.resp_body)

    assert %{"error" => %{"code" => -32_021}} =
             ProtocolTest.modern_stdio_request(
               server_name,
               2,
               "subscriptions/listen",
               params
             )

    allowed_request =
      modern_request("subscriptions/listen", params, tasks_capabilities())

    assert {:ok, subscriber, ^allowed_request} =
             Engine.start_subscription(server_name, allowed_request)

    assert_receive {:fastest_mcp_subscription_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    GenServer.stop(subscriber)
  end

  test "modern response validation ignores legacy task augmentation unless the result is a task" do
    server_name = unique_name("tasks-legacy-augmentation")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool("sync", fn _arguments, _context -> "synchronous" end)
      |> FastestMCP.add_tool("async", fn _arguments, _context -> "asynchronous" end,
        task: [mode: :required]
      )

    start_server!(server_name, server)

    sync_request =
      modern_request("tools/call", %{
        "name" => "sync",
        "arguments" => %{},
        "task" => %{"ttl" => 60_000, "pollInterval" => 100}
      })
      |> Map.put(:task_request, true)

    sync_result = Engine.dispatch!(server_name, sync_request)
    assert sync_result["resultType"] == "complete"
    assert %{"result" => ^sync_result} = JSONRPC.success(sync_request, sync_result)

    task_request =
      modern_request(
        "tools/call",
        %{"name" => "async", "arguments" => %{}},
        tasks_capabilities()
      )

    task_result = Engine.dispatch!(server_name, task_request)
    assert task_result["resultType"] == "task"
    assert %{"result" => ^task_result} = JSONRPC.success(task_request, task_result)
  end

  test "modern Tasks augmentation is restricted to tools/call" do
    server_name = unique_name("tasks-tools-only")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_prompt("draft", fn _arguments, _context -> "prompt body" end,
        task: [mode: :required]
      )
      |> FastestMCP.add_resource("memo://status", fn _arguments, _context -> "ready" end,
        task: [mode: :required]
      )

    start_server!(server_name, server)

    prompt_result =
      Engine.dispatch!(
        server_name,
        modern_request(
          "prompts/get",
          %{"name" => "draft", "arguments" => %{}},
          tasks_capabilities()
        )
      )

    resource_result =
      Engine.dispatch!(
        server_name,
        modern_request("resources/read", %{"uri" => "memo://status"}, tasks_capabilities())
      )

    assert prompt_result["resultType"] == "complete"
    refute Map.has_key?(prompt_result, "taskId")
    assert resource_result["resultType"] == "complete"
    refute Map.has_key?(resource_result, "taskId")
  end

  test "Tasks is an explicit server extension and does not change legacy task capabilities" do
    disabled = unique_name("tasks-disabled")

    disabled_server =
      FastestMCP.server(disabled)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end, task: true)

    start_server!(disabled, disabled_server)

    disabled_discovery = Engine.dispatch!(disabled, modern_request("server/discover", %{}))
    refute get_in(disabled_discovery, ["capabilities", "extensions", Extensions.tasks()])

    assert %{"resultType" => "complete"} =
             Engine.dispatch!(
               disabled,
               modern_request("tools/call", %{"name" => "echo", "arguments" => %{}})
             )

    disabled_error =
      assert_raise Error, fn ->
        Engine.dispatch!(
          disabled,
          modern_request(
            "tasks/get",
            %{"taskId" => "unavailable"},
            tasks_capabilities()
          )
        )
      end

    assert disabled_error.code == :method_not_found

    legacy_initialize = FastestMCP.initialize(disabled, %{}, transport: :in_process)
    assert get_in(legacy_initialize, ["capabilities", "tasks", "requests", "tools", "call"])

    enabled = unique_name("tasks-enabled")

    enabled_server =
      FastestMCP.server(enabled, extensions: tasks_extensions())
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end, task: true)

    start_server!(enabled, enabled_server)

    assert %{} =
             get_in(
               Engine.dispatch!(enabled, modern_request("server/discover", %{})),
               ["capabilities", "extensions", Extensions.tasks()]
             )

    assert %{"resultType" => "task", "taskId" => task_id, "status" => "working"} =
             Engine.dispatch!(
               enabled,
               modern_request(
                 "tools/call",
                 %{"name" => "echo", "arguments" => %{"value" => "background"}},
                 tasks_capabilities()
               )
             )

    assert is_binary(task_id)
  end

  test "required Tasks tools return -32021 when the client omits the extension" do
    server_name = unique_name("tasks-required")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool("required", fn _arguments, _context -> %{ok: true} end,
        task: [mode: :required, poll_interval_ms: 10]
      )

    start_server!(server_name, server)

    error =
      assert_raise Error, fn ->
        Engine.dispatch!(
          server_name,
          modern_request("tools/call", %{"name" => "required", "arguments" => %{}})
        )
      end

    assert error.code == :missing_required_client_capability
    assert error.details.jsonrpc_code == -32_021

    assert error.details.requiredCapabilities == %{
             extensions: %{Extensions.tasks() => %{}}
           }

    lifecycle_error =
      assert_raise Error, fn ->
        Engine.dispatch!(
          server_name,
          modern_request("tasks/get", %{"taskId" => "not-checked-without-capability"})
        )
      end

    assert lifecycle_error.code == :missing_required_client_capability
    assert lifecycle_error.details.jsonrpc_code == -32_021
  end

  test "tasks/get, tasks/update, and tasks/cancel implement the modern lifecycle" do
    server_name = unique_name("tasks-lifecycle")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool(
        "ask",
        fn _arguments, context ->
          case Context.input_responses(context) do
            %{} = responses when map_size(responses) == 0 ->
              InputRequiredResult.new(%{
                "answer" => %{
                  "method" => "elicitation/create",
                  "params" => %{"message" => "Answer"}
                }
              })

            %{"answer" => answer} ->
              %{"answer" => answer}
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )
      |> FastestMCP.add_tool(
        "block",
        fn _arguments, _context ->
          receive do
            :release -> %{released: true}
          after
            5_000 -> %{timed_out: true}
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )
      |> FastestMCP.add_tool(
        "tool_error",
        fn _arguments, _context ->
          %{isError: true, content: [%{type: "text", text: "tool rejected input"}]}
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server_name, server)

    %{"taskId" => ask_id} =
      Engine.dispatch!(
        server_name,
        modern_request(
          "tools/call",
          %{"name" => "ask", "arguments" => %{}},
          tasks_capabilities()
        )
      )

    assert %{
             "resultType" => "complete",
             "status" => "input_required",
             "inputRequests" => %{"answer" => %{"method" => "elicitation/create"}}
           } = wait_for_status(server_name, ask_id, "input_required")

    assert %{"resultType" => "complete"} =
             task_request(server_name, "tasks/update", %{
               "taskId" => ask_id,
               "inputResponses" => %{"answer" => %{"action" => "accept", "content" => "yes"}}
             })

    assert %{
             "resultType" => "complete",
             "status" => "completed",
             "result" => %{"structuredContent" => %{"answer" => answer}}
           } = wait_for_status(server_name, ask_id, "completed")

    assert answer == %{"action" => "accept", "content" => "yes"}

    %{"taskId" => tool_error_id} =
      Engine.dispatch!(
        server_name,
        modern_request(
          "tools/call",
          %{"name" => "tool_error", "arguments" => %{}},
          tasks_capabilities()
        )
      )

    assert %{
             "status" => "completed",
             "result" => %{"isError" => true},
             "resultType" => "complete"
           } = wait_for_status(server_name, tool_error_id, "completed")

    %{"taskId" => block_id} =
      Engine.dispatch!(
        server_name,
        modern_request(
          "tools/call",
          %{"name" => "block", "arguments" => %{}},
          tasks_capabilities()
        )
      )

    assert %{"resultType" => "complete"} =
             task_request(server_name, "tasks/cancel", %{"taskId" => block_id})

    assert %{"status" => "cancelled", "resultType" => "complete"} =
             wait_for_status(server_name, block_id, "cancelled")

    for method <- ["tasks/result", "tasks/list"] do
      error =
        assert_raise Error, fn ->
          task_request(server_name, method, %{"taskId" => ask_id})
        end

      assert error.code == :method_not_found
    end
  end

  test "a connected modern client follows a server-directed task to its result" do
    parent = self()
    server_name = unique_name("tasks-client")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool(
        "echo",
        fn arguments, _context ->
          send(parent, {:task_worker, self()})

          receive do
            :release -> arguments
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server_name, server)
    bandit = start_http_transport!(server_name)
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool(client, "echo", %{"value" => "modern"}, task: false)

    assert_receive {:task_worker, worker}, 1_000

    listener =
      Client.listen(client, %{"taskIds" => [task_id]},
        on_notification: fn message -> send(parent, {:task_notification, message}) end
      )

    assert_receive {:task_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   1_000

    send(worker, :release)

    assert_receive {:task_notification,
                    %{
                      "method" => "notifications/tasks",
                      "params" => %{
                        "taskId" => ^task_id,
                        "status" => "completed",
                        "result" => %{"structuredContent" => %{"value" => "modern"}}
                      }
                    }},
                   1_000

    assert %{"taskId" => ^task_id, "status" => "completed"} =
             RemoteTask.wait(task, timeout_ms: 2_000)

    assert %{"value" => "modern"} = RemoteTask.result(task, timeout_ms: 2_000)
    assert :ok = Client.cancel(listener, "test complete")
  end

  test "modern task response descriptors accept discriminators and result metadata" do
    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "resultType" => "task",
        "taskId" => "task-1",
        "status" => "working",
        "createdAt" => "2026-08-14T00:00:00Z",
        "lastUpdatedAt" => "2026-08-14T00:00:00Z",
        "ttlMs" => 60_000,
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "schema-test", "version" => "1"}
        }
      }
    }

    assert {:ok, ^response} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :task_response,
               "tools/call",
               response
             )

    refute Schema.protocol_supported?(
             "2025-11-25",
             :client_to_server,
             :request,
             "tasks/update"
           )
  end

  defp wait_for_status(server_name, task_id, status, attempts \\ 100)

  defp wait_for_status(server_name, task_id, status, attempts) when attempts > 0 do
    task = task_request(server_name, "tasks/get", %{"taskId" => task_id})

    if task["status"] == status do
      task
    else
      Process.sleep(10)
      wait_for_status(server_name, task_id, status, attempts - 1)
    end
  end

  defp wait_for_status(_server_name, task_id, status, 0) do
    flunk("task #{task_id} did not reach #{status}")
  end

  defp task_request(server_name, method, params) do
    Engine.dispatch!(server_name, modern_request(method, params, tasks_capabilities()))
  end

  defp modern_request(method, params, client_capabilities \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities,
      "io.modelcontextprotocol/clientInfo" => @client_info
    }

    %Request{
      method: method,
      transport: :stdio,
      protocol: :jsonrpc,
      protocol_version: @modern_version,
      request_id: System.unique_integer([:positive]),
      payload: Map.put(params, "_meta", meta)
    }
  end

  defp tasks_extensions, do: %{Extensions.tasks() => %{}}

  defp tasks_capabilities do
    %{
      "extensions" => tasks_extensions(),
      "elicitation" => %{"form" => %{}}
    }
  end

  defp start_server!(server_name, server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
  end

  defp start_http_transport!(server_name) do
    start_supervised!(
      {Bandit,
       plug:
         {FastestMCP.Transport.HTTPApp,
          server_name: server_name, path: "/mcp", allowed_hosts: ["127.0.0.1", "localhost"]},
       scheme: :http,
       port: 0}
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
