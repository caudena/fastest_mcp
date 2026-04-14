defmodule FastestMCP.TaskContextParityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Debug
  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context

  test "background tasks preserve submit-time access token and lifespan context" do
    parent = self()
    server_name = "task-context-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_lifespan(fn _server -> %{"db" => "connected", "cache" => "warm"} end)
      |> FastestMCP.add_tool(
        "inspect_context",
        fn _args, ctx ->
          send(
            parent,
            {:task_context_snapshot, Context.access_token(ctx), ctx.lifespan_context,
             ctx.session_id, Context.origin_request_id(ctx)}
          )

          :ok
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    task =
      FastestMCP.call_tool(server_name, "inspect_context", %{},
        task: true,
        session_id: "task-context-session",
        request_metadata: %{headers: %{"authorization" => "Bearer submit-token"}}
      )

    assert FastestMCP.await_task(task, 1_000) == :ok

    assert_receive {:task_context_snapshot, "submit-token",
                    %{"cache" => "warm", "db" => "connected"}, "task-context-session",
                    origin_request_id},
                   1_000

    assert is_binary(origin_request_id)
    assert String.starts_with?(origin_request_id, "req-")
  end

  test "authenticated background task handles preserve submit-time owner scope" do
    server_name = "task-auth-handle-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(Debug,
        validate: &(&1 == "alpha"),
        client_id: "alpha-client",
        principal: %{"sub" => "alpha-user"}
      )
      |> FastestMCP.add_tool("echo", fn _args, _ctx -> :ok end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    task =
      FastestMCP.call_tool(server_name, "echo", %{},
        task: true,
        auth_input: %{"authorization" => "Bearer alpha"}
      )

    assert %BackgroundTask{owner_fingerprint: owner_fingerprint} = task
    assert is_binary(owner_fingerprint)
    assert :ok == FastestMCP.await_task(task, 1_000)
    assert %{status: :completed} = FastestMCP.fetch_task(task)
    assert :ok == FastestMCP.task_result(task)
  end
end
