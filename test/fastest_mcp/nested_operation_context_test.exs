defmodule FastestMCP.NestedOperationContextTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context

  test "nested synchronous calls inherit the caller session context" do
    server_name = "nested-sync-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("inner", fn _args, ctx ->
        %{
          session_id: ctx.session_id,
          shared: Context.get_session_state(ctx, :shared, false)
        }
      end)
      |> FastestMCP.add_tool("outer", fn _args, ctx ->
        :ok = Context.put_session_state(ctx, :shared, true)
        FastestMCP.call_tool(server_name, "inner", %{})
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{session_id: "nested-session", shared: true} ==
             FastestMCP.call_tool(server_name, "outer", %{}, session_id: "nested-session")
  end

  test "nested task submissions inherit caller session but not the transport credential" do
    server_name = "nested-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "inner",
        fn _args, ctx ->
          %{
            session_id: ctx.session_id,
            access_token: Context.access_token(ctx)
          }
        end,
        task: true
      )
      |> FastestMCP.add_tool("outer", fn _args, _ctx ->
        task = FastestMCP.call_tool(server_name, "inner", %{}, task: true)
        %{task_id: task.task_id}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result =
      FastestMCP.call_tool(
        server_name,
        "outer",
        %{},
        session_id: "nested-session",
        request_metadata: %{headers: %{"authorization" => "Bearer nested-token"}}
      )

    task_id = result.task_id

    assert FastestMCP.fetch_task(server_name, task_id, session_id: "nested-session").session_id ==
             "nested-session"

    assert %{session_id: "nested-session", access_token: nil} ==
             FastestMCP.await_task(server_name, task_id, 1_000, session_id: "nested-session")
  end

  test "nested calls preserve request scope and negotiated client context" do
    server_name = "nested-request-scope-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("inner", fn _args, ctx ->
        %{
          session_id: ctx.session_id,
          state_scope: ctx.state_scope,
          protocol_version: ctx.negotiated_protocol_version,
          client_capabilities: ctx.client_capabilities
        }
      end)
      |> FastestMCP.add_tool("outer", fn _args, _ctx ->
        FastestMCP.call_tool(server_name, "inner", %{})
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             session_id: nil,
             state_scope: :request,
             protocol_version: "2025-11-25",
             client_capabilities: %{"sampling" => %{}}
           } ==
             FastestMCP.call_tool(server_name, "outer", %{},
               state_scope: :request,
               negotiated_protocol_version: "2025-11-25",
               client_capabilities: %{"sampling" => %{}}
             )
  end
end
