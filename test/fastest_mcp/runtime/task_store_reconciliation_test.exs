defmodule FastestMCP.Runtime.TaskStoreReconciliationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.Error
  alias FastestMCP.TaskRecord

  defmodule Backend do
    # Its state is an Agent holding the tasks a previous runtime stored.
    @behaviour FastestMCP.TaskBackend

    @impl true
    def init(agent: agent), do: {:ok, agent}

    @impl true
    def put_task(agent, task) do
      Agent.update(agent, &put_in(&1.tasks[task.id], task))
      {:ok, agent}
    end

    @impl true
    def fetch_task(agent, task_id) do
      case Agent.get(agent, &Map.fetch(&1.tasks, task_id)) do
        {:ok, task} -> {:ok, task}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def delete_task(agent, task_id) do
      Agent.update(agent, &update_in(&1.tasks, fn tasks -> Map.delete(tasks, task_id) end))
      {:ok, agent}
    end

    @impl true
    def list_tasks(agent) do
      Agent.get(agent, fn
        %{fail_list: true} -> {:error, :backend_unavailable}
        state -> {:ok, Map.values(state.tasks)}
      end)
    end
  end

  test "startup fails the tasks a previous runtime left active and drops expired ones" do
    now = System.system_time(:millisecond)

    tasks = [
      %TaskRecord{id: "working", ttl_ms: 10_000, submitted_at: 1, updated_at: 1},
      %TaskRecord{
        id: "waiting",
        status: :input_required,
        ttl_ms: 10_000,
        submitted_at: 2,
        updated_at: 2,
        elicitation: %{request_id: "elicit-1", message: "Approve?", requested_schema: %{}}
      },
      %TaskRecord{id: "expired", status: :completed, ttl_ms: 10, expires_at: now - 1},
      %TaskRecord{id: "finished", status: :completed, ttl_ms: 60_000, expires_at: now + 60_000}
    ]

    backend = start_backend!(tasks)

    assert {:ok, store} =
             BackgroundTaskStore.start_link(
               server_name: "reconcile",
               task_backend: {Backend, agent: backend}
             )

    stored = Agent.get(backend, & &1.tasks)
    assert stored |> Map.keys() |> Enum.sort() == ["finished", "waiting", "working"]
    assert stored["finished"].status == :completed

    for id <- ["working", "waiting"] do
      assert %TaskRecord{
               status: :failed,
               error: %Error{code: :runtime_restarted},
               failure_message: "Runtime restarted",
               elicitation: nil,
               completed_at: completed_at,
               expires_at: expires_at
             } = stored[id]

      assert expires_at == completed_at + 10_000
    end

    GenServer.stop(store)
  end

  test "startup fails when the durable backend cannot be listed" do
    backend = start_backend!([], fail_list: true)
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {:task_backend_startup_failed, :backend_unavailable}} =
             BackgroundTaskStore.start_link(
               server_name: "reconcile-failure",
               task_backend: {Backend, agent: backend}
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "waiter timers and caller monitors remove abandoned waits" do
    backend = start_backend!([])

    assert {:ok, store} =
             BackgroundTaskStore.start_link(
               server_name: "waiter-cleanup",
               task_backend: {Backend, agent: backend}
             )

    {:ok, _backend} =
      Backend.put_task(backend, %TaskRecord{
        id: "waiting-task",
        ttl_ms: 60_000,
        submitted_at: 1,
        updated_at: 1
      })

    caller = spawn(fn -> BackgroundTaskStore.await(store, "waiting-task", :infinity) end)

    assert_eventually(fn -> map_size(:sys.get_state(store).waiters) == 1 end)
    Process.exit(caller, :kill)

    assert_eventually(fn ->
      :sys.get_state(store).waiters == %{} and Process.info(store, :monitors) == {:monitors, []}
    end)

    assert {:error, %Error{code: :timeout}} = BackgroundTaskStore.await(store, "waiting-task", 1)

    assert_eventually(fn ->
      :sys.get_state(store).waiters == %{} and Process.info(store, :monitors) == {:monitors, []}
    end)

    GenServer.stop(store)
  end

  defp start_backend!(tasks, opts \\ []) do
    state = %{
      tasks: Map.new(tasks, &{&1.id, &1}),
      fail_list: Keyword.get(opts, :fail_list, false)
    }

    start_supervised!({Agent, fn -> state end})
  end
end
