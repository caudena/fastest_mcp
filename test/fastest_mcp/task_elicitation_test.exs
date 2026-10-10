defmodule FastestMCP.TaskElicitationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Elicitation.Cancelled
  alias FastestMCP.Elicitation.Declined
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.ServerRuntime

  test "background tasks can elicit input and resume through the local API" do
    server_name = "task-elicit-local-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "ask_name",
      fn _args, ctx ->
        case Context.elicit(ctx, "What is your name?", :string) do
          %Accepted{data: name} -> "Hello, #{name}!"
          %Declined{} -> "User declined"
          %Cancelled{} -> "Cancelled"
        end
      end,
      task: true
    )
    |> start_server!()

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    :ok = FastestMCP.EventBus.subscribe(runtime.event_bus, server_name)

    handle = FastestMCP.call_tool!(server_name, "ask_name", %{}, task: true)
    notification = wait_for_input_required_notification(server_name, handle.task_id)

    assert notification.notification["params"]["taskId"] == handle.task_id
    assert notification.notification["params"]["status"] == "input_required"
    assert notification.notification["params"]["statusMessage"] == "What is your name?"
    assert notification.related_task["taskId"] == handle.task_id
    assert notification.related_task["status"] == "input_required"

    assert %{
             "requestId" => request_id,
             "message" => "What is your name?",
             "requestedSchema" => %{
               "type" => "object",
               "properties" => %{"value" => %{"type" => "string"}},
               "required" => ["value"]
             }
           } = notification.related_task["elicitation"]

    task = FastestMCP.fetch_task!(handle)
    assert task.status == :input_required
    assert task.elicitation.request_id == request_id

    updated =
      FastestMCP.send_task_input!(server_name, handle.task_id, :accept, %{"value" => "Alice"})

    assert updated.status == :working
    assert FastestMCP.await_task!(handle, 1_000) == "Hello, Alice!"
  end

  test "scalar elicitation schemas wrap input and preserve field metadata" do
    server_name =
      "task-elicit-scalar-metadata-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "ask_name",
      fn _args, ctx ->
        case Context.elicit(ctx, "What is your name?", :string,
               response_title: "Name",
               response_description: "The display name to use"
             ) do
          %Accepted{data: name} -> "Hello, #{name}!"
          %Declined{} -> "User declined"
          %Cancelled{} -> "Cancelled"
        end
      end,
      task: true
    )
    |> start_server!()

    handle = FastestMCP.call_tool!(server_name, "ask_name", %{}, task: true)
    await_task_status(server_name, handle.task_id, :input_required)

    assert %{
             "type" => "object",
             "properties" => %{
               "value" => %{
                 "type" => "string",
                 "title" => "Name",
                 "description" => "The display name to use"
               }
             },
             "required" => ["value"]
           } = FastestMCP.fetch_task!(handle).elicitation.requested_schema

    _ = FastestMCP.send_task_input!(server_name, handle.task_id, :accept, %{"value" => "Alice"})
    assert FastestMCP.await_task!(handle, 1_000) == "Hello, Alice!"
  end

  test "send_task_input rejects non-waiting tasks and supports decline/cancel outcomes" do
    server_name = "task-elicit-outcomes-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "choose",
      fn %{"mode" => mode}, ctx ->
        case Context.elicit(ctx, "Provide input?", :string) do
          %Accepted{data: value} -> "#{mode}:#{value}"
          %Declined{} -> "#{mode}:declined"
          %Cancelled{} -> "#{mode}:cancelled"
        end
      end,
      task: true
    )
    |> FastestMCP.add_tool("done", fn _args, _ctx -> :ok end, task: true)
    |> start_server!()

    declined = FastestMCP.call_tool!(server_name, "choose", %{"mode" => "first"}, task: true)
    await_task_status(server_name, declined.task_id, :input_required)
    _ = FastestMCP.send_task_input!(server_name, declined.task_id, :decline, nil)
    assert FastestMCP.await_task!(declined, 1_000) == "first:declined"

    cancelled = FastestMCP.call_tool!(server_name, "choose", %{"mode" => "second"}, task: true)
    await_task_status(server_name, cancelled.task_id, :input_required)
    _ = FastestMCP.send_task_input!(server_name, cancelled.task_id, :cancel, nil)
    assert FastestMCP.await_task!(cancelled, 1_000) == "second:cancelled"

    completed = FastestMCP.call_tool!(server_name, "done", %{}, task: true)
    assert FastestMCP.await_task!(completed, 1_000) == :ok

    error =
      assert_raise Error, fn ->
        FastestMCP.send_task_input!(server_name, completed.task_id, :accept, %{"value" => "late"})
      end

    assert error.code == :bad_request
  end

  test "send_task_input names update_task for a task that waits for sampling" do
    server_name = unique_name("task-input-sampling")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "summarize",
      fn _args, ctx -> FastestMCP.Sampling.run!(ctx, "Summarize").text end,
      task: true
    )
    |> start_server!()

    task =
      FastestMCP.call_tool!(server_name, "summarize", %{},
        task: true,
        client_capabilities: %{"sampling" => %{}}
      )

    await_task_status(server_name, task.task_id, :input_required)

    error =
      assert_raise Error, fn ->
        FastestMCP.send_task_input!(server_name, task.task_id, :accept, %{"text" => "Short"})
      end

    assert error.code == :bad_request
    assert error.message =~ "sampling/createMessage"
    assert error.message =~ "FastestMCP.update_task/4"
    assert FastestMCP.fetch_task!(task).status == :input_required
  end

  test "a task that waits for the answers of an InputRequiredResult times out" do
    server_name = unique_name("task-input-timeout")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "ask",
      fn _args, _ctx ->
        InputRequiredResult.new(%{"name" => name_request()}, timeout_ms: 100)
      end,
      task: true
    )
    |> start_server!()

    task =
      FastestMCP.call_tool!(server_name, "ask", %{},
        task: true,
        client_capabilities: %{"elicitation" => %{"form" => %{}}}
      )

    assert {:error, %Error{code: :timeout}} = FastestMCP.await_task(task, 2_000)
    assert FastestMCP.fetch_task!(task).status == :failed
  end

  test "on 2025-11-25 an InputRequiredResult fails its task at once" do
    server_name = unique_name("task-input-legacy")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "ask",
      fn _args, _ctx -> InputRequiredResult.new(%{"name" => name_request()}) end,
      task: true
    )
    |> start_server!()

    client =
      connect!({:in_process, server_name},
        protocol_version: "2025-11-25",
        elicitation_handler: fn _message, _params -> {:accept, %{"value" => "Ada"}} end
      )

    task = Client.call_tool_task!(client, "ask", %{}, task: true)
    error = assert_raise Error, fn -> RemoteTask.result!(task, timeout_ms: 2_000) end
    assert error.message =~ "not valid under 2025-11-25"
  end

  test "task functions return documented FastestMCP.TaskRecord structs" do
    server_name = unique_name("task-record")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("done", fn _args, _ctx -> :ok end, task: true)
    |> start_server!()

    task = FastestMCP.call_tool!(server_name, "done", %{}, task: true)
    assert FastestMCP.await_task!(task) == :ok

    assert %{__struct__: FastestMCP.TaskRecord, status: :completed, result: :ok} =
             FastestMCP.fetch_task!(task)

    assert %{tasks: [%{__struct__: FastestMCP.TaskRecord}]} = FastestMCP.list_tasks!(server_name)

    assert {:docs_v1, _anno, :elixir, _format, %{"en" => _moduledoc}, _metadata, _docs} =
             Code.fetch_docs(FastestMCP.TaskRecord)
  end

  defp name_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "mode" => "form",
        "message" => "Name?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      }
    }
  end

  defp wait_for_input_required_notification(server_name, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_input_required_notification(server_name, task_id, deadline)
  end

  defp do_wait_for_input_required_notification(server_name, task_id, deadline) do
    receive do
      {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, event} ->
        related_task = event.related_task

        cond do
          related_task["taskId"] == task_id and
              event.notification["params"]["status"] == "input_required" ->
            event

          System.monotonic_time(:millisecond) >= deadline ->
            flunk(
              "timed out waiting for input_required notification for task #{inspect(task_id)}"
            )

          true ->
            do_wait_for_input_required_notification(server_name, task_id, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("timed out waiting for input_required notification for task #{inspect(task_id)}")
    end
  end
end
