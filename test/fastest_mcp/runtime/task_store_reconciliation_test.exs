defmodule FastestMCP.Runtime.TaskStoreReconciliationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.Error

  defmodule Backend do
    @behaviour FastestMCP.TaskBackend

    @impl true
    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          tasks: opts |> Keyword.get(:tasks, []) |> Map.new(&{&1.id, &1}),
          list_calls: 0,
          fail_list: Keyword.get(opts, :fail_list, false)
        }
      end)
    end

    @impl true
    def put_task(store, task) do
      Agent.update(store, &put_in(&1, [:tasks, task.id], task))
    end

    @impl true
    def fetch_task(store, task_id, _opts) do
      Agent.get(store, fn state ->
        case Map.fetch(state.tasks, task_id) do
          {:ok, task} -> {:ok, task}
          :error -> {:error, :not_found}
        end
      end)
    end

    @impl true
    def delete_task(store, task_id) do
      Agent.update(store, &update_in(&1.tasks, fn tasks -> Map.delete(tasks, task_id) end))
    end

    @impl true
    def list_tasks(store, opts) do
      Agent.get_and_update(store, fn state ->
        next_state = Map.update!(state, :list_calls, &(&1 + 1))

        if state.fail_list do
          {{:error, :backend_unavailable}, next_state}
        else
          page_size = Keyword.get(opts, :page_size, 500)
          offset = if opts[:cursor], do: String.to_integer(opts[:cursor]), else: 0
          tasks = state.tasks |> Map.values() |> Enum.sort_by(& &1.id)
          page = Enum.slice(tasks, offset, page_size)
          next_offset = offset + length(page)
          next_cursor = if next_offset < length(tasks), do: Integer.to_string(next_offset)

          {{:ok, %{tasks: page, next_cursor: next_cursor}}, next_state}
        end
      end)
    end

    @impl true
    def expire_tasks(_store, _now_ms), do: {:ok, []}
  end

  test "startup reconciles active tasks in bounded pages" do
    tasks =
      for index <- 1..501 do
        %{
          id: "task-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          status: if(rem(index, 2) == 0, do: :working, else: :input_required),
          ttl_ms: 10_000,
          submitted_at: index,
          updated_at: index,
          completed_at: nil,
          expires_at: nil,
          pid: self(),
          monitor_ref: make_ref(),
          elicitation: %{},
          interaction_status_message: "waiting"
        }
      end

    {:ok, backend} = Backend.start_link(tasks: tasks)

    assert {:ok, store} =
             BackgroundTaskStore.start_link(
               server_name: "reconcile",
               event_bus: self(),
               backend: %{module: Backend, store: backend}
             )

    state = Agent.get(backend, & &1)
    assert state.list_calls == 2

    assert Enum.all?(state.tasks, fn {_id, task} ->
             task.status == :failed and
               match?(%Error{code: :runtime_restarted}, task.error) and
               is_integer(task.completed_at) and task.expires_at == task.completed_at + 10_000 and
               is_nil(task.pid) and is_nil(task.monitor_ref)
           end)

    GenServer.stop(store)
    Agent.stop(backend)
  end

  test "startup fails when the durable backend cannot be listed" do
    {:ok, backend} = Backend.start_link(fail_list: true)
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {:task_backend_startup_failed, :backend_unavailable}} =
             BackgroundTaskStore.start_link(
               server_name: "reconcile-failure",
               event_bus: self(),
               backend: %{module: Backend, store: backend}
             )

    Process.flag(:trap_exit, previous_trap_exit)
    Agent.stop(backend)
  end

  test "waiter timers and caller monitors remove abandoned waits" do
    {:ok, backend} = Backend.start_link([])

    assert {:ok, store} =
             BackgroundTaskStore.start_link(
               server_name: "waiter-cleanup",
               event_bus: self(),
               backend: %{module: Backend, store: backend}
             )

    :ok =
      Backend.put_task(backend, %{
        id: "waiting-task",
        status: :working,
        submitted_at: 1,
        updated_at: 1,
        expires_at: nil
      })

    caller =
      spawn(fn ->
        BackgroundTaskStore.await(store, "waiting-task", :infinity)
      end)

    assert_eventually(fn -> map_size(:sys.get_state(store).waiter_monitors) == 1 end)
    Process.exit(caller, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(store)
      state.waiters == %{} and state.waiter_monitors == %{}
    end)

    assert {:error, %Error{code: :timeout}} =
             BackgroundTaskStore.await(store, "waiting-task", 1)

    assert_eventually(fn ->
      state = :sys.get_state(store)
      state.waiters == %{} and state.waiter_monitors == %{}
    end)

    GenServer.stop(store)
    Agent.stop(backend)
  end

  defp assert_eventually(fun, attempts \\ 50) do
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
