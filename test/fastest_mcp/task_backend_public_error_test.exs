defmodule FastestMCP.TaskBackendPublicErrorTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  defmodule Backend do
    use Agent

    @behaviour FastestMCP.TaskBackend

    @impl true
    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)

      Agent.start_link(fn ->
        send(owner, {:task_backend_started, self()})
        %{tasks: %{}, failures: %{}}
      end)
    end

    def fail(store, callback, reason) do
      Agent.update(store, &put_in(&1, [:failures, callback], reason))
    end

    def clear_failure(store, callback) do
      Agent.update(
        store,
        &update_in(&1.failures, fn failures -> Map.delete(failures, callback) end)
      )
    end

    @impl true
    def put_task(store, task) do
      Agent.get_and_update(store, fn state ->
        case state.failures[:put_task] do
          nil -> {:ok, put_in(state, [:tasks, task.id], task)}
          reason -> {{:error, reason}, state}
        end
      end)
    end

    @impl true
    def fetch_task(store, task_id, _opts) do
      Agent.get(store, fn state ->
        case state.failures[:fetch_task] do
          nil ->
            case Map.fetch(state.tasks, task_id) do
              {:ok, task} -> {:ok, task}
              :error -> {:error, :not_found}
            end

          reason ->
            {:error, reason}
        end
      end)
    end

    @impl true
    def delete_task(store, task_id) do
      Agent.get_and_update(store, fn state ->
        case state.failures[:delete_task] do
          nil -> {:ok, update_in(state.tasks, &Map.delete(&1, task_id))}
          reason -> {{:error, reason}, state}
        end
      end)
    end

    @impl true
    def list_tasks(store, _opts) do
      Agent.get(store, fn state ->
        case state.failures[:list_tasks] do
          nil -> {:ok, %{tasks: Map.values(state.tasks), next_cursor: nil}}
          reason -> {:error, reason}
        end
      end)
    end

    @impl true
    def expire_tasks(store, _now_ms) do
      Agent.get(store, fn state ->
        case state.failures[:expire_tasks] do
          nil -> {:ok, []}
          reason -> {:error, reason}
        end
      end)
    end
  end

  setup do
    server_name = "task-backend-public-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("done", fn _arguments, _context -> :done end, task: true)

    assert {:ok, _pid} =
             FastestMCP.start_server(server, task_backend: {Backend, owner: self()})

    assert_receive {:task_backend_started, backend}, 1_000
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    %{backend: backend, server_name: server_name}
  end

  test "public task APIs normalize arbitrary backend failures", context do
    operations = [
      {:fetch, &FastestMCP.fetch_task(context.server_name, &1)},
      {:await, &FastestMCP.await_task(context.server_name, &1, 100)},
      {:result, &FastestMCP.task_result(context.server_name, &1)},
      {:cancel, &FastestMCP.cancel_task(context.server_name, &1)},
      {:send_input, &FastestMCP.send_task_input(context.server_name, &1, :accept)}
    ]

    Enum.each(operations, fn {operation, invoke} ->
      task = FastestMCP.call_tool(context.server_name, "done", %{}, task: true)
      Backend.fail(context.backend, :fetch_task, {:storage_unavailable, operation})

      error = assert_raise Error, fn -> invoke.(task.task_id) end

      assert error.code == :internal_error
      assert error.message == "background task storage #{operation} failed"
      assert error.details == %{reason: inspect({:storage_unavailable, operation})}

      Backend.clear_failure(context.backend, :fetch_task)
    end)

    Backend.fail(context.backend, :list_tasks, :storage_unavailable)
    error = assert_raise Error, fn -> FastestMCP.list_tasks(context.server_name) end

    assert error.code == :internal_error
    assert error.message == "background task storage list failed"
    assert error.details == %{reason: ":storage_unavailable"}
  end

  test "stdio converts backend failures into an internal JSON-RPC error", context do
    task = FastestMCP.call_tool(context.server_name, "done", %{}, task: true)
    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(context.server_name)

    Backend.fail(context.backend, :fetch_task, :storage_unavailable)

    response =
      ProtocolTest.stdio_request(
        context.server_name,
        connection_id,
        2,
        "tasks/get",
        %{"taskId" => task.task_id}
      )

    assert response["id"] == 2
    assert get_in(response, ["error", "code"]) == -32_603

    assert get_in(response, ["error", "data", "fastestmcp"]) == %{
             "code" => "internal_error",
             "details" => %{"reason" => ":storage_unavailable"}
           }
  end
end
