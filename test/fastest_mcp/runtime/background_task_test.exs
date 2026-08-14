defmodule FastestMCP.Runtime.BackgroundTaskTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime

  defmodule TokenAuth do
    @behaviour FastestMCP.Auth

    alias FastestMCP.Auth.Result
    alias FastestMCP.Error

    @impl true
    def authenticate(%{"authorization" => "Bearer " <> token}, _context, _opts) do
      {:ok,
       %Result{
         principal: %{"sub" => token},
         auth: %{"client_id" => token, "token" => token},
         capabilities: [token]
       }}
    end

    def authenticate(_input, _context, _opts) do
      {:error, %Error{code: :unauthorized, message: "missing credentials"}}
    end
  end

  test "task-enabled tool returns a handle, exposes background context, and stores progress" do
    parent = self()
    server_name = "background-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "slow",
        fn _arguments, ctx ->
          send(
            parent,
            {:task_ctx, self(), Context.background_task?(ctx), Context.task_id(ctx),
             Context.origin_request_id(ctx), ctx.transport}
          )

          Context.report_progress(ctx, 1, 2, "Half done")

          receive do
            :release -> :done
          after
            1_000 -> :timed_out
          end
        end,
        task: [mode: :optional, poll_interval_ms: 250]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    :ok = FastestMCP.EventBus.subscribe(runtime.event_bus, server_name)

    handle = FastestMCP.call_tool(server_name, "slow", %{}, task: true)
    assert %BackgroundTask{} = handle
    assert handle.poll_interval_ms == 250

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    notification},
                   1_000

    assert notification.notification.method == "notifications/tasks/status"
    assert notification.notification.params.taskId == handle.task_id
    assert notification.notification.params.status == "working"
    assert notification.related_task.taskId == handle.task_id

    assert_receive {:task_ctx, worker_pid, true, task_id, origin_request_id, :background_task},
                   1_000

    assert task_id == handle.task_id
    assert is_binary(origin_request_id)
    assert String.starts_with?(origin_request_id, "req-")

    task = FastestMCP.fetch_task(handle)
    assert task.status == :working
    assert task.origin_request_id == origin_request_id

    assert task.progress == %{
             current: 1,
             total: 2,
             message: "Half done",
             reported_at: task.progress.reported_at
           }

    assert_receive {:fastest_mcp_event, ^server_name, [:task, :progress], measurements, metadata},
                   1_000

    assert measurements.current == 1
    assert measurements.total == 2
    assert measurements.message == "Half done"
    assert metadata.task_id == task_id
    assert metadata.origin_request_id == origin_request_id

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    progress_notification},
                   1_000

    assert progress_notification.notification.params.taskId == task_id
    assert progress_notification.notification.params.status == "working"
    assert progress_notification.notification.params.statusMessage == "Half done"
    refute Map.has_key?(progress_notification.notification, :_meta)

    send(worker_pid, :release)
    assert FastestMCP.await_task(handle, 1_000) == :done

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    completed_notification},
                   1_000

    assert completed_notification.notification.params.taskId == task_id
    assert completed_notification.notification.params.status == "completed"
    refute Map.has_key?(completed_notification.notification, :_meta)

    completed = FastestMCP.fetch_task(handle)
    assert completed.status == :completed
    assert completed.result == :done
  end

  test "resources and prompts can run as local background tasks" do
    server_name = "background-read-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("file://report.txt", fn _args, _ctx -> "report body" end,
        task: true
      )
      |> FastestMCP.add_prompt(
        "summary",
        fn _args, _ctx ->
          %{messages: [%{role: "user", content: "Hello from prompt"}], description: "Summary"}
        end,
        task: [mode: :required, poll_interval_ms: 150]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    resource_task = FastestMCP.read_resource(server_name, "file://report.txt", task: true)
    assert %BackgroundTask{} = resource_task
    assert FastestMCP.await_task(resource_task, 1_000) == "report body"

    prompt_task = FastestMCP.render_prompt(server_name, "summary", %{}, task: true)
    assert %BackgroundTask{} = prompt_task
    assert prompt_task.poll_interval_ms == 150

    assert FastestMCP.await_task(prompt_task, 1_000) == %{
             messages: [%{role: "user", content: %{type: "text", text: "Hello from prompt"}}],
             description: "Summary"
           }
  end

  test "task mode is enforced for forbidden and required components" do
    server_name = "background-modes-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sync_only", fn _args, _ctx -> :ok end, task: false)
      |> FastestMCP.add_tool("task_only", fn _args, _ctx -> :ok end, task: [mode: :required])

    assert {:ok, _pid} = FastestMCP.start_server(server)

    forbidden_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "sync_only", %{}, task: true)
      end

    assert forbidden_error.code == :method_not_found

    required_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "task_only", %{})
      end

    assert required_error.code == :method_not_found

    tools = FastestMCP.list_tools(server_name)

    assert Enum.find(tools, &(&1.name == "sync_only")).task == %{
             mode: "forbidden",
             poll_interval_ms: 5_000
           }

    assert Enum.find(tools, &(&1.name == "task_only")).task == %{
             mode: "required",
             poll_interval_ms: 5_000
           }
  end

  test "background task capacity rejects excess submissions" do
    parent = self()
    server_name = "background-capacity-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _arguments, _ctx ->
          send(parent, {:entered, self()})

          receive do
            :release -> :ok
          after
            1_000 -> :timed_out
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server, max_background_tasks: 1)

    first = FastestMCP.call_tool(server_name, "wait", %{}, task: true)
    assert %BackgroundTask{} = first
    assert_receive {:entered, first_pid}, 1_000

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "wait", %{}, task: true)
      end

    assert error.code == :overloaded

    send(first_pid, :release)
    assert FastestMCP.await_task(first, 1_000) == :ok
  end

  test "receiver task execution holds its originating session until terminal completion" do
    parent = self()
    server_name = "background-session-hold-#{System.unique_integer([:positive])}"
    session_id = "task-session"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _arguments, _context ->
          send(parent, {:task_started, self()})

          receive do
            :release -> :done
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server, session_idle_ttl: 30)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    handle = FastestMCP.call_tool(server_name, "wait", %{}, task: true, session_id: session_id)
    assert_receive {:task_started, task_pid}, 1_000
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    Process.sleep(75)
    assert Process.alive?(session_pid)
    assert map_size(:sys.get_state(session_pid).receiver_tasks) == 1

    monitor = Process.monitor(session_pid)
    send(task_pid, :release)
    assert :done = FastestMCP.await_task(handle, 1_000)

    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
  end

  test "concurrent background tasks preserve isolated request and auth context" do
    parent = self()
    server_name = "background-context-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(TokenAuth)
      |> FastestMCP.add_tool(
        "capture",
        fn %{"label" => label}, ctx ->
          send(parent, {
            :captured_context,
            label,
            self(),
            ctx.principal,
            ctx.auth,
            ctx.capabilities,
            ctx.request_metadata,
            Context.access_token(ctx)
          })

          receive do
            :release -> label
          after
            1_000 -> :timed_out
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    alpha =
      FastestMCP.call_tool(server_name, "capture", %{"label" => "alpha"},
        task: true,
        auth_input: %{"authorization" => "Bearer alpha"},
        request_metadata: %{headers: %{"authorization" => "Bearer alpha"}, marker: "alpha"}
      )

    beta =
      FastestMCP.call_tool(server_name, "capture", %{"label" => "beta"},
        task: true,
        auth_input: %{"authorization" => "Bearer beta"},
        request_metadata: %{headers: %{"authorization" => "Bearer beta"}, marker: "beta"}
      )

    contexts =
      for _ <- 1..2, into: %{} do
        assert_receive {:captured_context, label, pid, principal, auth, capabilities,
                        request_metadata, access_token},
                       1_000

        {label,
         %{
           pid: pid,
           principal: principal,
           auth: auth,
           capabilities: capabilities,
           request_metadata: request_metadata,
           access_token: access_token
         }}
      end

    assert contexts["alpha"].principal == %{"sub" => "alpha"}
    assert contexts["alpha"].auth == %{"client_id" => "alpha", "token" => "alpha"}
    assert contexts["alpha"].capabilities == ["alpha"]
    assert contexts["alpha"].request_metadata.marker == "alpha"
    assert contexts["alpha"].access_token == "alpha"

    assert contexts["beta"].principal == %{"sub" => "beta"}
    assert contexts["beta"].auth == %{"client_id" => "beta", "token" => "beta"}
    assert contexts["beta"].capabilities == ["beta"]
    assert contexts["beta"].request_metadata.marker == "beta"
    assert contexts["beta"].access_token == "beta"

    refute contexts["alpha"].pid == contexts["beta"].pid

    send(contexts["alpha"].pid, :release)
    send(contexts["beta"].pid, :release)

    assert FastestMCP.await_task(alpha, 1_000) == "alpha"
    assert FastestMCP.await_task(beta, 1_000) == "beta"
  end

  test "crashed background tasks are marked failed and surface the crash error" do
    server_name = "background-crash-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "explode",
        fn _arguments, _ctx ->
          exit(:boom)
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    handle = FastestMCP.call_tool(server_name, "explode", %{}, task: true)

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task(handle, 1_000)
      end

    assert error.code == :component_crash
    assert error.message =~ "explode"
    assert error.message =~ "exited"

    task = FastestMCP.fetch_task(handle)
    assert task.status == :failed
    assert %Error{code: :component_crash} = task.error
  end
end
