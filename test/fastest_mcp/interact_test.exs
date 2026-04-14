defmodule FastestMCP.InteractTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Interact

  test "confirm builds a boolean form and returns accepted boolean values" do
    server_name = "interact-confirm-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "confirm",
        fn _arguments, ctx ->
          case Interact.confirm(ctx, "Proceed?") do
            {:ok, true} -> "approved"
            {:ok, false} -> "rejected"
            :declined -> "declined"
            :cancelled -> "cancelled"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    approved = FastestMCP.call_tool(server_name, "confirm", %{}, task: true)
    :ok = wait_for_input_required(server_name, approved.task_id)

    assert %{
             "type" => "object",
             "properties" => %{"confirmed" => %{"type" => "boolean"}},
             "required" => ["confirmed"]
           } = FastestMCP.fetch_task(approved).elicitation.requested_schema

    _ = FastestMCP.send_task_input(server_name, approved.task_id, :accept, %{"confirmed" => true})
    assert FastestMCP.await_task(approved, 1_000) == "approved"

    rejected = FastestMCP.call_tool(server_name, "confirm", %{}, task: true)
    :ok = wait_for_input_required(server_name, rejected.task_id)

    _ =
      FastestMCP.send_task_input(server_name, rejected.task_id, :accept, %{"confirmed" => false})

    assert FastestMCP.await_task(rejected, 1_000) == "rejected"
  end

  test "choose maps keyword choices back to Elixir values" do
    server_name = "interact-choose-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "pick",
        fn _arguments, ctx ->
          case Interact.choose(ctx, "Pick a color", red: "r", blue: "b") do
            {:ok, value} -> value
            :declined -> "declined"
            :cancelled -> "cancelled"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    handle = FastestMCP.call_tool(server_name, "pick", %{}, task: true)
    :ok = wait_for_input_required(server_name, handle.task_id)

    assert %{
             "type" => "object",
             "properties" => %{
               "choice" => %{
                 "type" => "string",
                 "oneOf" => [
                   %{"const" => "red", "title" => "red"},
                   %{"const" => "blue", "title" => "blue"}
                 ]
               }
             },
             "required" => ["choice"]
           } = FastestMCP.fetch_task(handle).elicitation.requested_schema

    _ = FastestMCP.send_task_input(server_name, handle.task_id, :accept, %{"choice" => "blue"})
    assert FastestMCP.await_task(handle, 1_000) == "b"
  end

  test "text and form wrap the field DSL into accepted values" do
    server_name = "interact-form-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "ask_name",
        fn _arguments, ctx ->
          case Interact.text(ctx, "What is your name?") do
            {:ok, name} -> name
            :declined -> "declined"
            :cancelled -> "cancelled"
          end
        end,
        task: true
      )
      |> FastestMCP.add_tool(
        "profile",
        fn _arguments, ctx ->
          case Interact.form(ctx, "Profile", name: [type: :string, required: true], age: :integer) do
            {:ok, data} ->
              %{
                name: data["name"] || data[:name],
                age: data["age"] || data[:age]
              }

            :declined ->
              %{"status" => "declined"}

            :cancelled ->
              %{"status" => "cancelled"}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    ask_name = FastestMCP.call_tool(server_name, "ask_name", %{}, task: true)
    :ok = wait_for_input_required(server_name, ask_name.task_id)

    assert %{
             "type" => "object",
             "properties" => %{"value" => %{"type" => "string"}},
             "required" => ["value"]
           } = FastestMCP.fetch_task(ask_name).elicitation.requested_schema

    _ = FastestMCP.send_task_input(server_name, ask_name.task_id, :accept, %{"value" => "Alice"})
    assert FastestMCP.await_task(ask_name, 1_000) == "Alice"

    profile = FastestMCP.call_tool(server_name, "profile", %{}, task: true)
    :ok = wait_for_input_required(server_name, profile.task_id)

    assert %{
             "type" => "object",
             "properties" => %{
               "name" => %{"type" => "string"},
               "age" => %{"type" => "integer"}
             },
             "required" => ["name", "age"]
           } = FastestMCP.fetch_task(profile).elicitation.requested_schema

    _ =
      FastestMCP.send_task_input(
        server_name,
        profile.task_id,
        :accept,
        %{"name" => "Alice", "age" => 34}
      )

    assert %{name: "Alice", age: 34} = FastestMCP.await_task(profile, 1_000)
  end

  defp wait_for_input_required(server_name, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_input_required(server_name, task_id, deadline)
  end

  defp do_wait_for_input_required(server_name, task_id, deadline) do
    task = FastestMCP.fetch_task(server_name, task_id)

    cond do
      task.status == :input_required ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for task #{inspect(task_id)} to reach input_required")

      true ->
        Process.sleep(10)
        do_wait_for_input_required(server_name, task_id, deadline)
    end
  end
end
