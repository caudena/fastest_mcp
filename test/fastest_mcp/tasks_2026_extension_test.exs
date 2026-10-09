defmodule FastestMCP.Tasks2026ExtensionTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolResult
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
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

    assert ProtocolSchema.supported?(
             @modern_version,
             :server_to_client,
             :notification,
             "notifications/tasks"
           )

    refute ProtocolSchema.supported?(
             @modern_version,
             :client_to_server,
             :notification,
             "notifications/tasks"
           )

    assert {:ok, ^notification} =
             ProtocolSchema.validate(
               @modern_version,
               :server_to_client,
               :notification,
               "notifications/tasks",
               notification
             )
  end

  test "HTTP and stdio reject task subscription filters without the Tasks capability" do
    server_name = unique_name("tasks-subscription-capability")
    start_server!(FastestMCP.server(server_name, extensions: tasks_extensions()))

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

    assert {:ok, subscriber} =
             Engine.start_subscription(server_name, allowed_request)

    assert_receive {:fastest_mcp_subscription_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    GenServer.stop(subscriber)
  end

  test "modern response validation ignores legacy task augmentation unless the result is a task" do
    server_name = unique_name("tasks-legacy-augmentation")

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_tool("sync", fn _arguments, _context -> "synchronous" end)
    |> FastestMCP.add_tool("async", fn _arguments, _context -> "asynchronous" end,
      task: [mode: :required]
    )
    |> start_server!()

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

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_prompt("draft", fn _arguments, _context -> "prompt body" end,
      task: [mode: :required]
    )
    |> FastestMCP.add_resource("memo://status", fn _arguments, _context -> "ready" end,
      task: [mode: :required]
    )
    |> start_server!()

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

    FastestMCP.server(disabled)
    |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end, task: true)
    |> start_server!()

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

    legacy_initialize = FastestMCP.initialize!(disabled, %{}, transport: :in_process)
    assert get_in(legacy_initialize, ["capabilities", "tasks", "requests", "tools", "call"])

    enabled = unique_name("tasks-enabled")

    FastestMCP.server(enabled, extensions: tasks_extensions())
    |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end, task: true)
    |> start_server!()

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

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_tool("required", fn _arguments, _context -> %{ok: true} end,
      task: [mode: :required, poll_interval_ms: 10]
    )
    |> start_server!()

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
          FastestMCP.Tools.Result.from(%{
            isError: true,
            content: [%{type: "text", text: "tool rejected input"}]
          })
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server)

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

  test "a connected modern client transparently drives tasks and supports explicit handles" do
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
      |> FastestMCP.add_tool(
        "reject",
        fn _arguments, _context ->
          FastestMCP.Tools.Result.from(%{
            isError: true,
            content: [%{type: "text", text: "rejected"}]
          })
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )
      |> FastestMCP.add_tool(
        "large",
        fn _arguments, _context ->
          FastestMCP.Tools.Result.from(%{
            content: [%{type: "text", text: String.duplicate("x", 32_768)}]
          })
        end,
        task: [mode: :required, poll_interval_ms: 10]
      )

    start_server!(server)
    %{url: url} = start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost"])

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    bounded_client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info,
        max_response_bytes: 16_384
      )

    direct_client =
      connect!({:in_process, server_name},
        protocol_version: @modern_version,
        client_info: @client_info
      )

    call =
      Task.async(fn ->
        Client.call_tool!(client, "echo", %{"value" => "modern"},
          task: false,
          task_timeout_ms: 2_000
        )
      end)

    assert_receive {:task_worker, worker}, 1_000
    send(worker, :release)
    assert %{structured_content: %{"value" => "modern"}} = Task.await(call, 3_000)
    refute Client.info!(client).session_stream_open?

    stable_call =
      Task.async(fn ->
        Client.call_tool!(client, "echo", %{"value" => "stable"}, task_timeout_ms: 2_000)
      end)

    assert_receive {:task_worker, stable_worker}, 1_000
    send(stable_worker, :release)

    assert %ToolResult{
             structured_content: %{"value" => "stable"},
             structured_content_present?: true,
             is_error: false
           } = Task.await(stable_call, 3_000)

    cancellable =
      Client.start_tool_result!(client, "echo", %{"value" => "cancelled"}, task_timeout_ms: 2_000)

    assert_receive {:task_worker, cancellable_worker}, 1_000
    assert :ok = Client.ToolResultRequest.cancel!(cancellable, "test cancellation")

    cancellation =
      assert_raise Error, fn -> Client.ToolResultRequest.await!(cancellable, 2_000) end

    assert cancellation.code == :cancelled
    monitor = Process.monitor(cancellable_worker)
    assert_receive {:DOWN, ^monitor, :process, ^cancellable_worker, _reason}, 1_000

    direct =
      Client.start_tool_result!(direct_client, "echo", %{"value" => "cancelled-direct"},
        task_timeout_ms: 2_000
      )

    assert_receive {:task_worker, direct_worker}, 1_000
    assert :ok = Client.ToolResultRequest.cancel!(direct, "test direct cancellation")

    direct_cancellation =
      assert_raise Error, fn -> Client.ToolResultRequest.await!(direct, 2_000) end

    assert direct_cancellation.code == :cancelled
    direct_monitor = Process.monitor(direct_worker)
    assert_receive {:DOWN, ^direct_monitor, :process, ^direct_worker, _reason}, 1_000

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "rejected"}],
             is_error: true
           } = Client.call_tool!(client, "reject", %{}, task_timeout_ms: 2_000)

    oversized =
      assert_raise Error, fn ->
        Client.call_tool!(bounded_client, "large", %{}, task_timeout_ms: 2_000)
      end

    assert oversized.code == :bad_request
    assert oversized.message == "MCP response exceeds configured size limit"
    assert oversized.details.max_response_bytes == 16_384
    # The HTTP stream crosses the bound before its terminal frame is observed.
    # The caller must therefore preserve an unknown effect outcome.
    assert oversized.details.terminal_response_observed == false

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool_task!(client, "echo", %{"value" => "handle"})

    assert_receive {:task_worker, handle_worker}, 1_000

    listener =
      Client.listen!(client, %{"taskIds" => [task_id]},
        on_notification: fn message -> send(parent, {:task_notification, message}) end
      )

    assert_receive {:task_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   1_000

    result_waiter = Task.async(fn -> RemoteTask.result!(task, timeout_ms: 2_000) end)
    send(handle_worker, :release)

    assert_receive {:task_notification,
                    %{
                      "method" => "notifications/tasks",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   1_000

    assert %{structured_content: %{"value" => "handle"}} = Task.await(result_waiter, 3_000)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.status!(task)
    assert :ok = Client.Request.cancel!(listener, "test complete")

    assert %RemoteTask{} =
             compatibility_task =
             Client.call_tool_task!(client, "echo", %{"value" => "compatibility"}, task: true)

    assert_receive {:task_worker, compatibility_worker}, 1_000
    send(compatibility_worker, :release)

    assert %{structured_content: %{"value" => "compatibility"}} =
             RemoteTask.result!(compatibility_task, timeout_ms: 2_000)

    refute Client.info!(client).session_stream_open?
  end

  test "transparent modern tasks fulfill input-required callbacks with task context" do
    parent = self()
    server_name = unique_name("tasks-client-input")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool(
        "ask",
        fn _arguments, context ->
          case Context.input_responses(context) do
            responses when map_size(responses) == 0 ->
              InputRequiredResult.new(%{
                "answer" => %{
                  "method" => "elicitation/create",
                  "params" => %{
                    "message" => "Answer",
                    "requestedSchema" => %{"type" => "object", "properties" => %{}}
                  }
                }
              })

            %{"answer" => answer} ->
              %{"answer" => answer}
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server)
    %{url: url} = start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost"])

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info,
        elicitation_handler: fn _message, _params, context ->
          send(parent, {:task_callback_context, context.task_id})
          {:accept, %{"answer" => "yes"}}
        end
      )

    assert %{
             structured_content: %{
               "answer" => %{"action" => "accept", "content" => %{"answer" => "yes"}}
             }
           } =
             Client.call_tool!(client, "ask", %{}, task_timeout_ms: 2_000)

    assert_receive {:task_callback_context, task_id}, 1_000
    assert is_binary(task_id)
    refute Client.info!(client).session_stream_open?
  end

  defmodule RecordingPlug do
    @moduledoc false
    # Reports every MCP POST to the test before the HTTP app handles it, and
    # holds a request for the `hold:` method until the test releases it.

    def init(opts), do: opts

    def call(%Plug.Conn{method: "POST"} = conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = JSON.decode!(body)
      send(opts[:test_pid], {:mcp_request, payload})

      with hold when is_binary(hold) <- opts[:hold], %{"method" => ^hold} <- payload do
        send(opts[:test_pid], {:held, self()})
        receive do: (:release -> :ok)
      end

      FastestMCP.Transport.HTTPApp.call(%{conn | body_params: payload}, app(opts))
    end

    def call(conn, opts), do: FastestMCP.Transport.HTTPApp.call(conn, app(opts))

    defp app(opts) do
      FastestMCP.Transport.HTTPApp.init(
        server_name: opts[:server_name],
        path: "/mcp",
        allowed_hosts: ["127.0.0.1", "localhost"]
      )
    end
  end

  test "task results and waits forward per-call metadata to tasks/get" do
    parent = self()
    server_name = unique_name("tasks-client-meta")

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_tool(
      "slow",
      fn _arguments, _context ->
        send(parent, {:slow_started, self()})

        receive do
          :release -> %{"done" => true}
        end
      end,
      task: [mode: :optional, poll_interval_ms: 10]
    )
    |> start_server!()

    %{url: url} = serve!({RecordingPlug, test_pid: self(), server_name: server_name})

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    result =
      Task.async(fn ->
        Client.call_tool!(client, "slow", %{},
          meta: %{"example.com/marker" => "result"},
          task_timeout_ms: 2_000
        )
      end)

    # The call polls with its metadata while the tool is still running.
    assert_polled_with_marker("result")
    release_slow_tool()
    assert %ToolResult{structured_content: %{"done" => true}} = Task.await(result)

    task = Client.call_tool_task!(client, "slow", %{})

    waited =
      Task.async(fn ->
        RemoteTask.wait!(task, meta: %{"example.com/marker" => "wait"}, timeout_ms: 2_000)
      end)

    assert_polled_with_marker("wait")
    release_slow_tool()
    assert %{"status" => "completed"} = Task.await(waited)
  end

  # Two polls of a working task, so the client keeps waiting between them.
  defp assert_polled_with_marker(marker) do
    for _poll <- 1..2 do
      assert_receive {:mcp_request,
                      %{
                        "method" => "tasks/get",
                        "params" => %{"_meta" => %{"example.com/marker" => ^marker}}
                      }},
                     1_000
    end
  end

  defp release_slow_tool do
    assert_receive {:slow_started, tool}, 1_000
    send(tool, :release)
  end

  defmodule NonPositivePollIntervalPlug do
    @moduledoc false
    # Serves the HTTP app with every task status's pollIntervalMs set to 0,
    # which the Tasks schema (a number) admits.

    def init(opts), do: opts

    def call(conn, opts) do
      app =
        FastestMCP.Transport.HTTPApp.init(
          server_name: opts[:server_name],
          path: "/mcp",
          allowed_hosts: ["127.0.0.1", "localhost"]
        )

      conn
      |> Plug.Conn.register_before_send(&rewrite(&1, opts[:test_pid]))
      |> FastestMCP.Transport.HTTPApp.call(app)
    end

    defp rewrite(%Plug.Conn{resp_body: body} = conn, test_pid) when not is_nil(body) do
      case JSON.decode(IO.iodata_to_binary(body)) do
        {:ok, %{"result" => %{"pollIntervalMs" => _interval}} = payload} ->
          send(test_pid, :poll_interval_rewritten)
          %{conn | resp_body: JSON.encode!(put_in(payload, ["result", "pollIntervalMs"], 0))}

        _other ->
          conn
      end
    end

    defp rewrite(conn, _test_pid), do: conn
  end

  test "a non-positive task pollIntervalMs falls back to the default interval" do
    parent = self()
    server_name = unique_name("tasks-client-poll-interval")

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_tool(
      "slow",
      fn _arguments, _context ->
        send(parent, {:slow_started, self()})

        receive do
          :release -> %{"done" => true}
        end
      end,
      task: [mode: :optional, poll_interval_ms: 10]
    )
    |> start_server!()

    %{url: url} =
      serve!({NonPositivePollIntervalPlug, test_pid: self(), server_name: server_name})

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    result = Task.async(fn -> Client.call_tool(client, "slow", %{}, task_timeout_ms: 2_000) end)
    # The client sees a working task whose zero interval it must not use.
    assert_receive :poll_interval_rewritten, 1_000
    release_slow_tool()
    assert {:ok, %ToolResult{structured_content: %{"done" => true}}} = Task.await(result)

    task = Client.call_tool_task!(client, "slow", %{})
    waited = Task.async(fn -> RemoteTask.wait(task, timeout_ms: 2_000) end)
    release_slow_tool()
    assert {:ok, %{"status" => "completed"}} = Task.await(waited)
    assert_receive :poll_interval_rewritten, 1_000
  end

  test "transparent task timeout leaves the remote task running" do
    parent = self()
    server_name = unique_name("tasks-client-timeout")

    server =
      FastestMCP.server(server_name, extensions: tasks_extensions())
      |> FastestMCP.add_tool(
        "block",
        fn _arguments, _context ->
          send(parent, {:blocking_task_worker, self()})

          receive do
            :release -> %{released: true}
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server)
    %{url: url} = start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost"])

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    call =
      Task.async(fn ->
        try do
          Client.call_tool!(client, "block", %{}, task_timeout_ms: 500)
        rescue
          error in Error -> {:error, error}
        end
      end)

    assert_receive {:blocking_task_worker, worker}, 1_000
    assert {:error, %Error{code: :timeout}} = Task.await(call, 2_000)
    assert Process.alive?(worker)
    refute Client.info!(client).session_stream_open?
    send(worker, :release)
  end

  test "a terminal call cancels the remote task it drives when its caller exits" do
    server_name = blocking_task_server!()
    client = recording_client!(server_name)
    caller = spawn(fn -> Client.call_tool(client, "block", %{}, task_timeout_ms: 10_000) end)

    assert_receive {:blocking_task_worker, worker}, 1_000
    # The caller drives the task once it polls it.
    assert_receive {:mcp_request, %{"method" => "tasks/get", "params" => %{"taskId" => task_id}}},
                   1_000

    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:mcp_request,
                    %{"method" => "tasks/cancel", "params" => %{"taskId" => ^task_id}}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert %{"status" => "cancelled"} = wait_for_status(server_name, task_id, "cancelled")
  end

  test "a terminal call whose caller exits mid-request cancels the task the request creates" do
    server_name = blocking_task_server!()
    client = recording_client!(server_name, hold: "tools/call")
    caller = spawn(fn -> Client.call_tool(client, "block", %{}, task_timeout_ms: 10_000) end)

    assert_receive {:held, plug}, 1_000
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    send(plug, :release)

    assert_receive {:blocking_task_worker, worker}, 1_000
    monitor = Process.monitor(worker)

    assert_receive {:mcp_request,
                    %{"method" => "tasks/cancel", "params" => %{"taskId" => task_id}}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert %{"status" => "cancelled"} = wait_for_status(server_name, task_id, "cancelled")
  end

  test "an explicit task handle outlives the caller that created it" do
    parent = self()
    server_name = blocking_task_server!()
    client = recording_client!(server_name)
    caller = spawn(fn -> send(parent, {:handle, Client.call_tool_task(client, "block")}) end)

    assert_receive {:handle, {:ok, %RemoteTask{task_id: task_id}}}, 1_000
    assert_receive {:blocking_task_worker, worker}, 1_000
    monitor = Process.monitor(caller)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _reason}
    refute_receive {:mcp_request, %{"method" => "tasks/cancel"}}, 200
    send(worker, :release)
    assert %{"status" => "completed"} = wait_for_status(server_name, task_id, "completed")
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
             ProtocolSchema.validate(
               @modern_version,
               :server_to_client,
               :task_response,
               "tools/call",
               response
             )

    refute ProtocolSchema.supported?(
             "2025-11-25",
             :client_to_server,
             :request,
             "tasks/update"
           )
  end

  defp wait_for_status(server_name, task_id, status) do
    assert_eventually(fn ->
      task = task_request(server_name, "tasks/get", %{"taskId" => task_id})
      task["status"] == status && task
    end)
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

  # A modern server whose task-capable "block" tool runs until released.
  defp blocking_task_server! do
    parent = self()
    server_name = unique_name("tasks-client-owner")

    FastestMCP.server(server_name, extensions: tasks_extensions())
    |> FastestMCP.add_tool(
      "block",
      fn _arguments, _context ->
        send(parent, {:blocking_task_worker, self()})
        receive do: (:release -> %{released: true})
      end,
      task: [mode: :optional, poll_interval_ms: 10]
    )
    |> start_server!()

    server_name
  end

  # A modern HTTP client whose requests the test observes through RecordingPlug.
  defp recording_client!(server_name, plug_opts \\ []) do
    %{url: url} =
      serve!({RecordingPlug, [test_pid: self(), server_name: server_name] ++ plug_opts})

    client =
      connect!(url,
        protocol_version: @modern_version,
        extensions: tasks_extensions(),
        client_info: @client_info
      )

    client
  end
end
