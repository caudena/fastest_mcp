defmodule FastestMCP.ContextConvenienceTest do
  use FastestMCP.Case, async: true

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

    start_server!(server)

    assert %{
             explicit_request_id: request_id,
             nested_request_id: request_id,
             nested_session_id: "ctx-session",
             request_path: "/mcp",
             request_meta: %{"custom" => "value", "method" => "POST"}
           } =
             FastestMCP.call_tool!(server_name, "nested", %{},
               session_id: "ctx-session",
               request_metadata: %{
                 method: "POST",
                 path: "/mcp",
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
        path: "/mcp",
        query_params: %{"page" => "1"},
        headers: %{"authorization" => "Bearer token", "x-demo" => "1"},
        custom: "meta"
      }
    }

    assert %RequestContext{
             request_id: "req-1",
             transport: :streamable_http,
             path: "/mcp",
             query_params: %{"page" => "1"},
             headers: %{"x-demo" => "1"},
             meta: %{"custom" => "meta"}
           } = Context.request_context(context)
  end

  test "a context without a session id is request-scoped" do
    runtime = test_runtime(unique_name("ctx-no-session"))

    assert %Context{session_id: nil, state_scope: :request} = Context.new(runtime)

    assert %Context{session_id: nil, state_scope: :request} =
             Context.new(runtime, state_scope: :session)

    assert %Context{session_id: "chat", state_scope: :session} =
             Context.new(runtime, session_id: "chat")
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

    assert "principal-sub" ==
             Context.client_id(%Context{
               server_name: "ctx-client-id-sub",
               request_id: "req-3",
               transport: :test,
               principal: %{"sub" => "principal-sub"}
             })
  end

  test "client_id ignores the name the client reports for itself" do
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

    start_server!(server)

    assert is_map(
             FastestMCP.initialize!(
               server_name,
               %{"clientInfo" => %{"name" => "docs-client", "version" => "1.0.0"}},
               session_id: "ctx-client-info-session"
             )
           )

    assert %{
             client_id: nil,
             client_info: %{"name" => "docs-client", "version" => "1.0.0"}
           } =
             FastestMCP.call_tool!(server_name, "whoami", %{},
               session_id: "ctx-client-info-session"
             )

    modern =
      ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "whoami"},
        client_info: %{"name" => "docs-client", "version" => "1.0.0"},
        headers: [{"mcp-name", "whoami"}]
      )

    assert %{"result" => %{"structuredContent" => %{"client_id" => nil}}} =
             JSON.decode!(modern.resp_body)
  end

  test "request_meta returns the _meta of the client's request" do
    server_name = unique_name("ctx-request-meta")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("trace", fn _args, ctx -> Context.request_meta(ctx) end)
    |> start_server!()

    for version <- ["2025-11-25", "2026-07-28"] do
      client = connect!({:in_process, server_name}, protocol_version: version)

      assert %{"trace_id" => "trace-123"} =
               FastestMCP.Client.call_tool!(client, "trace", %{},
                 meta: %{"trace_id" => "trace-123"}
               ).structured_content
    end

    assert %{} == FastestMCP.call_tool!(server_name, "trace")
  end

  test "without a session, logs and progress go unsent, and notifications and visibility fail" do
    server_name = unique_name("ctx-no-session")
    attach_telemetry([[:fastest_mcp, :log, :message]])

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("report", fn _args, ctx ->
      %{
        log: inspect(Context.info(ctx, "working")),
        progress: inspect(Context.report_progress(ctx, 1, 2)),
        notification: inspect(Context.send_notification(ctx, "notifications/com.example/x"))
      }
    end)
    |> FastestMCP.add_tool("hide", fn _args, ctx ->
      :ok = Context.disable_components(ctx, names: ["report"])
      "hidden"
    end)
    |> start_server!()

    # In process, without a session: no client receives anything.
    assert %{
             log: ":filtered",
             progress: "{:error, :missing_progress_token}",
             notification: "{:error, :no_session}"
           } == FastestMCP.call_tool!(server_name, "report")

    refute_receive {:telemetry, [:fastest_mcp, :log, :message], _measurements,
                    %{server_name: ^server_name}},
                   50

    assert {:error, %FastestMCP.Error{code: :internal_error, message: message}} =
             FastestMCP.call_tool(server_name, "hide")

    assert message =~ "Context.disable_components/2 needs a 2025-11-25 session"
    assert "report" in Enum.map(FastestMCP.list_tools!(server_name), & &1.name)

    # A 2026-07-28 request answered with JSON, without a stream: the client
    # asked for logs and progress, but can't receive them.
    %{url: url} = start_http!(server_name, json_response: true)

    client =
      connect!(url, protocol_version: "2026-07-28", log_handler: fn _message -> :ok end)

    assert %{
             "log" => ":filtered",
             "progress" => "{:error, :missing_progress_token}",
             "notification" => "{:error, :no_session}"
           } ==
             FastestMCP.Client.call_tool!(client, "report", %{},
               progress_handler: fn _update -> :ok end
             ).structured_content

    assert {:error, %FastestMCP.Error{message: message}} =
             FastestMCP.Client.call_tool(client, "hide", %{})

    assert message =~ "needs a 2025-11-25 session"

    # With a session, the messages wait for the session's client.
    assert %{log: ":ok", notification: "{:ok, %{queued: true}}"} =
             FastestMCP.call_tool!(server_name, "report", %{}, session_id: "chat-1")

    assert "hidden" == FastestMCP.call_tool!(server_name, "hide", %{}, session_id: "chat-1")
  end

  test "list_peer_tasks without a session says that it needs a 2025-11-25 session" do
    server_name = unique_name("ctx-peer-tasks")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("peer_tasks", fn _args, ctx -> Context.list_peer_tasks(ctx) end)
    |> start_server!()

    assert {:error, %FastestMCP.Error{code: :internal_error, message: in_process}} =
             FastestMCP.call_tool(server_name, "peer_tasks")

    client = connect!({:in_process, server_name}, protocol_version: "2026-07-28")

    assert {:error, %FastestMCP.Error{message: modern}} =
             FastestMCP.Client.call_tool(client, "peer_tasks", %{})

    for message <- [in_process, modern] do
      assert message =~
               "Context.list_peer_tasks/2 needs a 2025-11-25 session, which this request doesn't have"
    end
  end

  test "current! raises outside a request" do
    assert_raise RuntimeError, ~r/requires an active FastestMCP request context/, fn ->
      Context.current!()
    end
  end
end
