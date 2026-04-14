defmodule FastestMCP.ContextConvenienceTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.RequestContext

  test "current! exposes the same context inside nested runtime helpers" do
    server_name = "context-current-" <> Integer.to_string(System.unique_integer([:positive]))

    nested = fn ->
      current = Context.current!()
      request = Context.request_context(current)

      %{
        request_id: current.request_id,
        session_id: current.session_id,
        request_context: request
      }
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("nested", fn _arguments, ctx ->
        nested_result = nested.()

        %{
          explicit_request_id: ctx.request_id,
          nested_request_id: nested_result.request_id,
          nested_session_id: nested_result.session_id,
          request_path: nested_result.request_context.path,
          request_meta: nested_result.request_context.meta
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             explicit_request_id: request_id,
             nested_request_id: request_id,
             nested_session_id: "ctx-session",
             request_path: "/mcp/tools/call",
             request_meta: %{"custom" => "value", "method" => "POST"}
           } =
             FastestMCP.call_tool(server_name, "nested", %{},
               session_id: "ctx-session",
               request_metadata: %{
                 method: "POST",
                 path: "/mcp/tools/call",
                 custom: "value"
               }
             )
  end

  test "request_context returns a stable wrapper struct" do
    context = %Context{
      server_name: "ctx-request-wrapper",
      session_id: "session-1",
      request_id: "req-1",
      transport: :streamable_http,
      request_metadata: %{
        path: "/mcp/prompts/get",
        query_params: %{"page" => "1"},
        headers: %{"authorization" => "Bearer token", "x-demo" => "1"},
        custom: "meta"
      }
    }

    assert %RequestContext{
             request_id: "req-1",
             transport: :streamable_http,
             path: "/mcp/prompts/get",
             query_params: %{"page" => "1"},
             headers: %{"authorization" => "Bearer token", "x-demo" => "1"},
             meta: %{"custom" => "meta"}
           } = Context.request_context(context)
  end

  test "build generates opaque random session ids when none are supplied" do
    server_name =
      "ctx-generated-session-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    assert {:ok, runtime} = FastestMCP.ServerRuntime.fetch(server_name)

    assert {:ok, context_a} =
             Context.build(server_name, session_supervisor: runtime.session_supervisor)

    assert {:ok, context_b} =
             Context.build(server_name, session_supervisor: runtime.session_supervisor)

    assert context_a.session_id =~ ~r/\A[0-9a-f]{32}\z/
    assert context_b.session_id =~ ~r/\A[0-9a-f]{32}\z/
    refute context_a.session_id == context_b.session_id

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)
  end

  test "client_id resolves from auth and principal payloads" do
    assert "auth-client" ==
             Context.client_id(%Context{
               server_name: "ctx-client-id-auth",
               session_id: "session-1",
               request_id: "req-1",
               transport: :test,
               auth: %{"client_id" => "auth-client"},
               principal: %{"sub" => "principal-sub"}
             })

    assert "principal-client" ==
             Context.client_id(%Context{
               server_name: "ctx-client-id-principal",
               session_id: "session-2",
               request_id: "req-2",
               transport: :test,
               principal: %{client_id: "principal-client"}
             })
  end

  test "client_id falls back to negotiated client info for the session" do
    server_name = "ctx-client-info-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("whoami", fn _arguments, ctx ->
        request = Context.request_context(ctx)

        %{
          client_id: Context.client_id(ctx),
          client_info: request.meta["clientInfo"]
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert is_map(
             FastestMCP.initialize(
               server_name,
               %{"clientInfo" => %{"name" => "docs-client", "version" => "1.0.0"}},
               session_id: "ctx-client-info-session"
             )
           )

    assert %{
             client_id: "docs-client",
             client_info: %{"name" => "docs-client", "version" => "1.0.0"}
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               session_id: "ctx-client-info-session"
             )
  end

  test "current! raises outside a request" do
    assert_raise RuntimeError, ~r/requires an active FastestMCP request context/, fn ->
      Context.current!()
    end
  end
end
