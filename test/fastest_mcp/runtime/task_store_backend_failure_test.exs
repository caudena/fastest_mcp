defmodule FastestMCP.Runtime.TaskStoreBackendFailureTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.BackgroundTaskSupervisor
  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Elicitation
  alias FastestMCP.EventBus
  alias FastestMCP.Operation
  alias FastestMCP.TaskConfig

  defmodule FailureBackend do
    use Agent

    @behaviour FastestMCP.TaskBackend

    @impl true
    def start_link(_opts) do
      Agent.start_link(fn -> %{tasks: %{}, failures: %{}, calls: []} end)
    end

    def fail(store, callback, reason) do
      Agent.update(store, &put_in(&1, [:failures, callback], reason))
    end

    def fail_after_write(store, :put_task, reason) do
      Agent.update(store, &put_in(&1, [:failures, :put_task], {:after_write, reason}))
    end

    def tasks(store), do: Agent.get(store, & &1.tasks)
    def calls(store), do: Agent.get(store, &Enum.reverse(&1.calls))

    @impl true
    def put_task(store, task) do
      Agent.get_and_update(store, fn state ->
        state = record_call(state, :put_task)

        case state.failures[:put_task] do
          {:after_write, reason} ->
            {{:error, reason}, put_in(state, [:tasks, task.id], task)}

          reason when not is_nil(reason) ->
            {{:error, reason}, state}

          nil ->
            {:ok, put_in(state, [:tasks, task.id], task)}
        end
      end)
    end

    @impl true
    def fetch_task(store, task_id, _opts) do
      Agent.get_and_update(store, fn state ->
        state = record_call(state, :fetch_task)

        reply =
          case state.failures[:fetch_task] do
            reason when not is_nil(reason) ->
              {:error, reason}

            nil ->
              case Map.fetch(state.tasks, task_id) do
                {:ok, task} -> {:ok, task}
                :error -> {:error, :not_found}
              end
          end

        {reply, state}
      end)
    end

    @impl true
    def delete_task(store, task_id) do
      Agent.get_and_update(store, fn state ->
        state = record_call(state, :delete_task)

        case state.failures[:delete_task] do
          reason when not is_nil(reason) ->
            {{:error, reason}, state}

          nil ->
            {:ok, update_in(state.tasks, &Map.delete(&1, task_id))}
        end
      end)
    end

    @impl true
    def list_tasks(store, _opts) do
      Agent.get_and_update(store, fn state ->
        state = record_call(state, :list_tasks)

        reply =
          case state.failures[:list_tasks] do
            reason when not is_nil(reason) ->
              {:error, reason}

            nil ->
              {:ok, %{tasks: Map.values(state.tasks), next_cursor: nil}}
          end

        {reply, state}
      end)
    end

    @impl true
    def expire_tasks(store, _now_ms) do
      Agent.get_and_update(store, fn state ->
        state = record_call(state, :expire_tasks)

        reply =
          case state.failures[:expire_tasks] do
            reason when not is_nil(reason) -> {:error, reason}
            nil -> {:ok, []}
          end

        {reply, state}
      end)
    end

    defp record_call(state, callback), do: update_in(state.calls, &[callback | &1])
  end

  setup do
    backend = start_supervised!(FailureBackend)
    event_bus = start_supervised!(EventBus)
    task_supervisor = start_supervised!(BackgroundTaskSupervisor)

    store =
      start_supervised!(
        {BackgroundTaskStore,
         server_name: "backend-failure",
         event_bus: event_bus,
         backend: %{module: FailureBackend, store: backend}}
      )

    %{
      backend: backend,
      event_bus: event_bus,
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

  test "expire_tasks failures fail the triggering call and release all orchestration", context do
    task = task_with_waiters(context)
    FailureBackend.fail(context.backend, :expire_tasks, :expire_failed)

    assert {:error, :expire_failed} = BackgroundTaskStore.fetch(context.store, task.task_id)
    assert_failure_cleanup(context.store, task, :expire_failed)
  end

  test "delete_task rollback failures are returned without leaking the submitted worker",
       context do
    FailureBackend.fail_after_write(context.backend, :put_task, :put_failed)
    FailureBackend.fail(context.backend, :delete_task, :delete_failed)

    parent = self()

    assert {:error, {:task_backend_rollback_failed, :put_failed, :delete_failed}} =
             submit_task(context, fn operation ->
               send(parent, {:rollback_worker, Context.task_id(operation.context), self()})

               receive do
                 :finish -> :done
               end
             end)

    assert_receive {:rollback_worker, task_id, worker_pid}, 1_000
    assert_eventually(fn -> not Process.alive?(worker_pid) end)
    assert Map.has_key?(FailureBackend.tasks(context.backend), task_id)
    assert :delete_task in FailureBackend.calls(context.backend)
    assert_clean_state(context.store)

    assert_eventually(fn ->
      Process.info(context.store, :message_queue_len) == {:message_queue_len, 0}
    end)
  end

  defp task_with_waiters(context) do
    parent = self()
    store = context.store

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
        reply = BackgroundTaskStore.elicit(context.store, task_id, request, 10_000)
        send(parent, {:interaction_reply, reply})
      end)

    assert_eventually(fn ->
      Map.has_key?(:sys.get_state(context.store).interaction_waiters, task_id)
    end)

    bridge_pid =
      spawn(fn ->
        receive do
          message ->
            send(parent, {:bridge_request, message})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(bridge_pid), do: send(bridge_pid, :stop)
    end)

    result_pid =
      spawn(fn ->
        reply =
          BackgroundTaskStore.result(context.store, task_id,
            timeout: 10_000,
            request_metadata: %{
              client_stream_pid: bridge_pid,
              client_request_store: parent
            }
          )

        send(parent, {:result_reply, reply})
      end)

    assert_receive {:bridge_request,
                    {:client_bridge_request, ^store, relay_id, _message, ^parent, _session_id,
                     10_000}},
                   1_000

    assert is_binary(relay_id)

    await_pid =
      spawn(fn ->
        reply = BackgroundTaskStore.await(context.store, task_id, 10_000)
        send(parent, {:await_reply, reply})
      end)

    assert_eventually(fn ->
      state = :sys.get_state(context.store)

      map_size(state.task_monitors) == 1 and
        map_size(state.waiter_monitors) == 3 and
        length(Map.get(state.waiters, task_id, [])) == 1 and
        length(Map.get(state.result_waiters, task_id, [])) == 1 and
        Map.has_key?(state.interaction_waiters, task_id) and
        state.relay_requests == %{relay_id => task_id}
    end)

    state = :sys.get_state(context.store)

    timer_refs =
      [
        get_in(state, [:waiters, task_id, Access.at(0), :timer_ref]),
        get_in(state, [:result_waiters, task_id, Access.at(0), :timer_ref]),
        get_in(state, [:interaction_waiters, task_id, :timer_ref])
      ]

    %{
      task_id: task_id,
      worker_pid: worker_pid,
      caller_pids: [interaction_pid, result_pid, await_pid],
      timer_refs: timer_refs
    }
  end

  defp submit_task(context, executor) do
    {:ok, request_context} =
      Context.build("backend-failure",
        state_scope: :request,
        transport: :in_process,
        event_bus: context.event_bus
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
      arguments: %{}
    }

    BackgroundTaskStore.submit(
      context.store,
      context.task_supervisor,
      component,
      operation,
      executor
    )
  end

  defp assert_failure_cleanup(store, task, reason) do
    assert_receive {:await_reply, {:error, ^reason}}, 1_000
    assert_receive {:result_reply, {:error, ^reason}}, 1_000
    assert_receive {:interaction_reply, {:error, ^reason}}, 1_000

    Enum.each(task.caller_pids, fn pid ->
      assert_eventually(fn -> not Process.alive?(pid) end)
    end)

    assert_eventually(fn -> not Process.alive?(task.worker_pid) end)
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

      state.task_monitors == %{} and
        state.waiter_monitors == %{} and
        state.waiters == %{} and
        state.result_waiters == %{} and
        state.interaction_waiters == %{} and
        state.relay_requests == %{} and
        Process.info(store, :monitors) == {:monitors, []}
    end)
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
    end
  end
end
