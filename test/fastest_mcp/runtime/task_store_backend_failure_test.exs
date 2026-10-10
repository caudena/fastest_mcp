defmodule FastestMCP.Runtime.TaskStoreBackendFailureTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Elicitation
  alias FastestMCP.EventBus
  alias FastestMCP.Operation
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionStateStore.Memory, as: SessionStateStore
  alias FastestMCP.TaskConfig

  defmodule FailureBackend do
    # Its state is an Agent the test starts, so tests can inject failures.
    @behaviour FastestMCP.TaskBackend

    def fail(agent, callback, reason),
      do: Agent.update(agent, &put_in(&1, [:failures, callback], reason))

    def fail_after_write(agent, :put_task, reason),
      do: Agent.update(agent, &put_in(&1, [:failures, :put_task], {:after_write, reason}))

    def tasks(agent), do: Agent.get(agent, & &1.tasks)
    def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

    @impl true
    def init(agent: agent), do: {:ok, agent}

    @impl true
    def put_task(agent, task) do
      call(agent, :put_task, fn
        state, {:after_write, reason} -> {{:error, reason}, put_in(state.tasks[task.id], task)}
        state, nil -> {{:ok, agent}, put_in(state.tasks[task.id], task)}
        state, reason -> {{:error, reason}, state}
      end)
    end

    @impl true
    def fetch_task(agent, task_id) do
      call(agent, :fetch_task, fn
        state, nil -> {Map.fetch(state.tasks, task_id) |> found(), state}
        state, reason -> {{:error, reason}, state}
      end)
    end

    @impl true
    def delete_task(agent, task_id) do
      call(agent, :delete_task, fn
        state, nil -> {{:ok, agent}, update_in(state.tasks, &Map.delete(&1, task_id))}
        state, reason -> {{:error, reason}, state}
      end)
    end

    @impl true
    def list_tasks(agent) do
      call(agent, :list_tasks, fn
        state, nil -> {{:ok, Map.values(state.tasks)}, state}
        state, reason -> {{:error, reason}, state}
      end)
    end

    defp call(agent, callback, fun) do
      Agent.get_and_update(agent, fn state ->
        fun.(update_in(state.calls, &[callback | &1]), state.failures[callback])
      end)
    end

    defp found(:error), do: {:error, :not_found}
    defp found(ok), do: ok
  end

  setup do
    server_name = "backend-failure-#{System.unique_integer([:positive])}"
    session_id = "backend-failure-session"
    backend = start_supervised!({Agent, fn -> %{tasks: %{}, failures: %{}, calls: []} end})
    event_bus = %EventBus{}
    task_supervisor = start_supervised!(Task.Supervisor, id: :task_supervisor)
    relay_task_supervisor = start_supervised!(Task.Supervisor, id: :relay_task_supervisor)
    session_state_store = start_supervised!(SessionStateStore)

    runtime_quota =
      RuntimeQuota.new(pending_requests: 10, active_requests: 10, sse_replay_bytes: 1_000_000)

    session =
      start_supervised!(
        {Session,
         %{
           server_name: server_name,
           session_id: session_id,
           idle_ttl_ms: :infinity,
           session_state_store: session_state_store,
           task_supervisor: relay_task_supervisor,
           runtime_quota: runtime_quota
         }}
      )

    :ok =
      Session.begin_initialization(server_name, session_id,
        client_capabilities: %{"elicitation" => %{"form" => %{}}},
        client_info: %{"name" => "backend failure test", "version" => "1"}
      )

    :ok = Session.mark_initialized(server_name, session_id)

    store =
      start_supervised!(
        {BackgroundTaskStore,
         server_name: server_name,
         event_bus: event_bus,
         task_backend: {FailureBackend, agent: backend},
         task_supervisor: task_supervisor,
         relay_task_supervisor: relay_task_supervisor}
      )

    %{
      server_name: server_name,
      session_id: session_id,
      backend: backend,
      event_bus: event_bus,
      session: session,
      store: store,
      task_supervisor: task_supervisor
    }
  end

  test "put_task failures release every task waiter and relay", context do
    task = task_with_waiters(context)
    FailureBackend.fail(context.backend, :put_task, :put_failed)

    assert {:error, :put_failed} =
             BackgroundTaskStore.send_input(
               context.store,
               task.task_id,
               :accept,
               %{"value" => "approved"}
             )

    assert_failure_cleanup(context.store, task, :put_failed)
  end

  test "fetch_task failures release every task waiter and relay", context do
    task = task_with_waiters(context)
    FailureBackend.fail(context.backend, :fetch_task, :fetch_failed)

    assert {:error, :fetch_failed} = BackgroundTaskStore.fetch(context.store, task.task_id)
    assert_failure_cleanup(context.store, task, :fetch_failed)
  end

  test "list_tasks failures release all active task orchestration", context do
    task = task_with_waiters(context)
    FailureBackend.fail(context.backend, :list_tasks, :list_failed)

    assert {:error, :list_failed} = BackgroundTaskStore.list(context.store)
    assert_failure_cleanup(context.store, task, :list_failed)
  end

  test "a finished task expires on its timer and stays hidden when it cannot be deleted",
       context do
    FailureBackend.fail(context.backend, :delete_task, :delete_failed)

    assert {:ok, handle} = submit_task(context, fn _operation -> :done end, 500)
    assert {:ok, :done} = BackgroundTaskStore.await(context.store, handle.task_id, 1_000)

    assert_eventually(fn -> :delete_task in FailureBackend.calls(context.backend) end, 5_000)
    assert {:error, :not_found} = BackgroundTaskStore.fetch(context.store, handle.task_id)
    assert {:ok, []} = BackgroundTaskStore.list(context.store)
    assert Map.has_key?(FailureBackend.tasks(context.backend), handle.task_id)
    assert_clean_state(context.store)
  end

  test "put_task failures reject a submission before its executor runs", context do
    FailureBackend.fail(context.backend, :put_task, :put_failed)
    parent = self()

    assert {:error, :put_failed} =
             submit_task(context, fn _operation ->
               send(parent, :rejected_executor_started)
               :done
             end)

    refute_receive :rejected_executor_started, 100

    assert_eventually(fn -> Task.Supervisor.children(context.task_supervisor) == [] end)

    assert_clean_state(context.store)
  end

  test "delete_task rollback failures are returned without running the submitted executor",
       context do
    FailureBackend.fail_after_write(context.backend, :put_task, :put_failed)
    FailureBackend.fail(context.backend, :delete_task, :delete_failed)

    parent = self()

    assert {:error, {:task_backend_rollback_failed, :put_failed, :delete_failed}} =
             submit_task(context, fn operation ->
               send(parent, {:rollback_worker, Context.task_id(operation.context)})
               :done
             end)

    refute_receive {:rollback_worker, _task_id}, 100
    assert [_task_id] = Map.keys(FailureBackend.tasks(context.backend))
    assert :delete_task in FailureBackend.calls(context.backend)

    assert_eventually(fn -> Task.Supervisor.children(context.task_supervisor) == [] end)

    assert_clean_state(context.store)

    assert_eventually(fn ->
      Process.info(context.store, :message_queue_len) == {:message_queue_len, 0}
    end)
  end

  defp task_with_waiters(context) do
    parent = self()

    assert {:ok, handle} =
             submit_task(context, fn operation ->
               send(parent, {:task_worker, Context.task_id(operation.context), self()})

               receive do
                 :finish -> :done
               end
             end)

    assert_receive {:task_worker, task_id, worker_pid}, 1_000
    assert task_id == handle.task_id

    request = Elicitation.request("Approve?", :string, timeout_ms: 10_000)

    interaction_pid =
      spawn(fn ->
        reply =
          BackgroundTaskStore.interact(context.store, task_id, :elicitation, request, 10_000)

        send(parent, {:interaction_reply, reply})
      end)

    assert_eventually(fn ->
      Map.has_key?(:sys.get_state(context.store).interactions, task_id)
    end)

    assert {:ok, sink} =
             Session.attach_sink(context.server_name, context.session_id, self(),
               kind: :post,
               origin_request_id: 55
             )

    sink_ref = sink.sink_ref

    result_pid =
      spawn(fn ->
        reply =
          BackgroundTaskStore.await(context.store, task_id, 10_000,
            session_id: context.session_id,
            request_metadata: %{
              session_sink_ref: sink_ref,
              jsonrpc_request_id: 55
            }
          )

        send(parent, {:result_reply, reply})
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => wire_request_id,
                      "method" => "elicitation/create"
                    }},
                   5_000

    assert is_binary(wire_request_id)

    await_pid =
      spawn(fn ->
        reply = BackgroundTaskStore.await(context.store, task_id, 10_000)
        send(parent, {:await_reply, reply})
      end)

    assert_eventually(
      fn ->
        state = :sys.get_state(context.store)

        Map.has_key?(state.running, task_id) and
          length(Map.get(state.waiters, task_id, [])) == 2 and
          match?(%{relay: %{pid: pid}} when is_pid(pid), state.interactions[task_id])
      end,
      5_000
    )

    state = :sys.get_state(context.store)

    timer_refs = [
      state.interactions[task_id].timer | Enum.map(state.waiters[task_id], & &1.timer)
    ]

    %{
      task_id: task_id,
      worker_pid: worker_pid,
      relay_worker_pid: state.interactions[task_id].relay.pid,
      session_pid: context.session,
      caller_pids: [interaction_pid, result_pid, await_pid],
      timer_refs: timer_refs
    }
  end

  defp submit_task(context, executor, ttl_ms \\ nil) do
    runtime = %ServerRuntime{
      server: FastestMCP.server(context.server_name),
      event_bus: context.event_bus
    }

    request_context =
      Context.new(runtime,
        state_scope: :request,
        session_id: context.session_id,
        transport: :in_process
      )

    component = %Tool{
      server_name: "backend-failure",
      name: "wait",
      version: "1.0.0",
      task: TaskConfig.new(true)
    }

    operation = %Operation{
      server_name: "backend-failure",
      method: "tools/call",
      component_type: :tool,
      target: "wait",
      context: request_context,
      transport: :in_process,
      task_ttl_ms: ttl_ms,
      arguments: %{}
    }

    BackgroundTaskStore.submit(context.store, component, operation, executor)
  end

  defp assert_failure_cleanup(store, task, reason) do
    assert_receive {:await_reply, {:error, ^reason}}, 1_000
    assert_receive {:result_reply, {:error, ^reason}}, 1_000
    assert_receive {:interaction_reply, {:error, ^reason}}, 1_000

    Enum.each(task.caller_pids, fn pid ->
      assert_eventually(fn -> not Process.alive?(pid) end)
    end)

    assert_eventually(fn -> not Process.alive?(task.worker_pid) end)
    assert_eventually(fn -> not Process.alive?(task.relay_worker_pid) end)

    assert_eventually(fn ->
      session_state = :sys.get_state(task.session_pid)
      session_state.pending_requests == %{} and session_state.pending_monitors == %{}
    end)

    assert_clean_state(store)

    Enum.each(task.timer_refs, fn timer_ref ->
      assert is_reference(timer_ref)
      assert Process.read_timer(timer_ref) == false
    end)

    assert_eventually(fn ->
      Process.info(store, :message_queue_len) == {:message_queue_len, 0}
    end)

    refute_receive {:await_reply, _reply}, 20
    refute_receive {:result_reply, _reply}, 20
    refute_receive {:interaction_reply, _reply}, 20
  end

  defp assert_clean_state(store) do
    assert_eventually(fn ->
      state = :sys.get_state(store)

      state.running == %{} and state.waiters == %{} and state.interactions == %{} and
        Process.info(store, :monitors) == {:monitors, []}
    end)
  end
end
