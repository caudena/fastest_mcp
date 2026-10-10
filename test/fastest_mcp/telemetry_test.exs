defmodule FastestMCP.TelemetryTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Error

  test "operation start, stop, and exception events are emitted" do
    attach_telemetry([
      [:fastest_mcp, :operation, :start],
      [:fastest_mcp, :operation, :stop],
      [:fastest_mcp, :operation, :exception]
    ])

    server_name = "telemetry-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("ok", fn _args, _ctx -> %{status: "ok"} end)
    |> FastestMCP.add_tool("fail", fn _args, _ctx -> raise "nope" end)
    |> start_server!()

    assert %{status: "ok"} == FastestMCP.call_tool!(server_name, "ok", %{})
    assert_raise Error, fn -> FastestMCP.call_tool!(server_name, "fail", %{}) end

    assert_receive {:telemetry, [:fastest_mcp, :operation, :start], _measurements,
                    %{method: "tools/call", server_name: ^server_name}},
                   1_000

    assert_receive {:telemetry, [:fastest_mcp, :operation, :stop], %{duration: duration},
                    %{method: "tools/call", server_name: ^server_name}},
                   1_000

    assert duration > 0

    assert_receive {:telemetry, [:fastest_mcp, :operation, :exception], _measurements,
                    %{method: "tools/call", server_name: ^server_name}},
                   1_000
  end

  test "auth start, stop, and exception events are emitted for authenticated operations" do
    attach_telemetry([
      [:fastest_mcp, :auth, :start],
      [:fastest_mcp, :auth, :stop],
      [:fastest_mcp, :auth, :exception]
    ])

    server_name = "auth-telemetry-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"valid-token" => %{client_id: "service-a", scopes: ["tools:call"]}},
      required_scopes: ["tools:call"]
    )
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    assert %{} ==
             FastestMCP.call_tool!(server_name, "echo", %{},
               auth_input: %{"authorization" => "Bearer valid-token"}
             )

    assert_raise Error, fn ->
      FastestMCP.call_tool!(server_name, "echo", %{}, auth_input: %{"token" => "missing"})
    end

    provider = inspect(FastestMCP.Auth.StaticToken)

    assert_receive {:telemetry, [:fastest_mcp, :auth, :start], _measurements,
                    %{server_name: ^server_name, method: "tools/call", auth_provider: ^provider}},
                   1_000

    assert_receive {:telemetry, [:fastest_mcp, :auth, :stop], %{duration: duration},
                    %{server_name: ^server_name, method: "tools/call", auth_provider: ^provider}},
                   1_000

    assert duration > 0

    assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], %{duration: failed_duration},
                    %{
                      server_name: ^server_name,
                      method: "tools/call",
                      auth_provider: ^provider,
                      code: :unauthorized
                    }},
                   1_000

    assert failed_duration > 0
  end

  test "HTTP requests emit the auth events, also when they are rejected" do
    attach_telemetry([
      [:fastest_mcp, :auth, :start],
      [:fastest_mcp, :auth, :stop],
      [:fastest_mcp, :auth, :exception]
    ])

    server_name = unique_name("http-auth-telemetry")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"valid-token" => %{client_id: "service-a"}}
    )
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    provider = inspect(FastestMCP.Auth.StaticToken)

    accepted =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "tools/call",
        %{"name" => "echo", "arguments" => %{}},
        headers: [{"authorization", "Bearer valid-token"}, {"mcp-name", "echo"}]
      )

    assert accepted.status == 200

    assert_receive {:telemetry, [:fastest_mcp, :auth, :start], %{system_time: _},
                    %{
                      server_name: ^server_name,
                      transport: :streamable_http,
                      method: "tools/call",
                      target: "echo",
                      component_type: :tool,
                      auth_provider: ^provider
                    }}

    assert_receive {:telemetry, [:fastest_mcp, :auth, :stop], %{duration: duration},
                    %{server_name: ^server_name, method: "tools/call", auth_provider: ^provider}}

    assert duration > 0

    rejected = ProtocolTest.modern_http_request(server_name, 2, "tools/list")
    assert rejected.status == 401

    assert_receive {:telemetry, [:fastest_mcp, :auth, :start], _measurements,
                    %{server_name: ^server_name, method: "tools/list", component_type: :tool}}

    assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], %{duration: _duration},
                    %{
                      server_name: ^server_name,
                      method: "tools/list",
                      auth_provider: ^provider,
                      code: :unauthorized,
                      error: "missing credentials"
                    }}

    # The transport authenticated the call, so the pipeline didn't do it again.
    refute_received {:telemetry, [:fastest_mcp, :auth, _event], _measurements,
                     %{server_name: ^server_name}}
  end

  test "the auth exception event of an authenticator that raised carries the exception" do
    attach_telemetry([[:fastest_mcp, :auth, :exception]])
    server_name = unique_name("auth-crash-telemetry")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn
      %{"authorization" => _token} = input, _ctx -> Map.fetch!(input, :user)
      _input, _ctx -> {:error, :unauthorized}
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    token = "Bearer token-in-the-auth-input"
    call = %{"name" => "echo"}

    assert {:error, %Error{code: :internal_error}} =
             FastestMCP.call_tool(server_name, "echo", %{},
               auth_input: %{"authorization" => token}
             )

    ProtocolTest.modern_stdio_request(server_name, 1, "tools/call", call,
      auth_input: %{"authorization" => token}
    )

    ProtocolTest.modern_http_request(server_name, 2, "tools/call", call,
      headers: [{"authorization", token}, {"mcp-name", "echo"}]
    )

    for transport <- [:in_process, :stdio, :streamable_http] do
      assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], %{duration: _duration},
                      %{
                        server_name: ^server_name,
                        transport: ^transport,
                        code: :internal_error,
                        error: "authenticator failed",
                        kind: :error,
                        reason: %KeyError{key: :user},
                        stacktrace: stacktrace
                      }}

      assert Exception.format_stacktrace(stacktrace) =~ "test/fastest_mcp/telemetry_test.exs"
    end

    # A rejection raised nothing, so its event has no exception.
    assert {:error, %Error{code: :unauthorized}} = FastestMCP.call_tool(server_name, "echo")

    assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], _measurements,
                    %{server_name: ^server_name, code: :unauthorized} = metadata}

    refute Map.has_key?(metadata, :reason)
  end

  test "an HTTP request's authentication events carry the request id of its operation" do
    attach_telemetry([
      [:fastest_mcp, :auth, :start],
      [:fastest_mcp, :auth, :stop],
      [:fastest_mcp, :operation, :start],
      [:fastest_mcp, :operation, :stop]
    ])

    server_name = unique_name("http-auth-request-id")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"valid-token" => %{client_id: "service-a"}}
    )
    |> FastestMCP.add_tool("request_id", fn _args, ctx -> %{request_id: ctx.request_id} end)
    |> start_server!()

    %{url: url} = start_http!(server_name)

    for version <- ["2026-07-28", "2025-11-25"] do
      client = connect!(url, protocol_version: version, access_token: "valid-token")

      %{structured_content: %{"request_id" => request_id}} =
        FastestMCP.Client.call_tool!(client, "request_id", %{})

      for event <- [[:auth, :start], [:auth, :stop], [:operation, :start], [:operation, :stop]] do
        event = [:fastest_mcp | event]

        assert_receive {:telemetry, ^event, _measurements,
                        %{
                          server_name: ^server_name,
                          method: "tools/call",
                          request_id: ^request_id
                        }}
      end
    end
  end

  test "the log message event carries the message as the client receives it" do
    attach_telemetry([[:fastest_mcp, :log, :message]])
    server_name = unique_name("log-telemetry")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("sign_in", fn _args, ctx ->
      ctx |> FastestMCP.Context.info(%{"user" => "ada", "password" => "hunter2"}) |> inspect()
    end)
    |> start_server!()

    redacted = %{"user" => "ada", "password" => "[REDACTED]"}

    # A 2025-11-25 session delivers the message.
    assert ":ok" == FastestMCP.call_tool!(server_name, "sign_in", %{}, session_id: "log-session")

    assert_receive {:telemetry, [:fastest_mcp, :log, :message], %{count: 1},
                    %{server_name: ^server_name, level: "info", data: ^redacted}}

    # A 2026-07-28 request delivers it on its response stream.
    response =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "tools/call",
        %{
          "name" => "sign_in",
          "arguments" => %{},
          "_meta" => %{"io.modelcontextprotocol/logLevel" => "info"}
        },
        headers: [{"mcp-name", "sign_in"}],
        json_response: false
      )

    assert response.status == 200

    assert_receive {:telemetry, [:fastest_mcp, :log, :message], %{count: 1},
                    %{server_name: ^server_name, transport: :streamable_http, data: ^redacted}}
  end

  test "progress outside a background task emits the operation's progress event" do
    attach_telemetry([[:fastest_mcp, :operation, :progress], [:fastest_mcp, :task, :progress]])
    server_name = unique_name("progress-telemetry")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "export_notes",
      fn _args, ctx ->
        FastestMCP.Context.report_progress(ctx, 1, 2, "Half done")
        "done"
      end,
      task: [mode: :optional]
    )
    |> start_server!()

    assert "done" == FastestMCP.call_tool!(server_name, "export_notes")

    assert_receive {:telemetry, [:fastest_mcp, :operation, :progress],
                    %{current: 1, total: 2, message: "Half done"},
                    %{server_name: ^server_name, transport: :in_process} = metadata}

    refute Map.has_key?(metadata, :task_id)

    refute_received {:telemetry, [:fastest_mcp, :task, :progress], _,
                     %{server_name: ^server_name}}

    task = FastestMCP.call_tool!(server_name, "export_notes", %{}, task: true)
    assert "done" == FastestMCP.await_task!(task, 1_000)
    task_id = task.task_id

    assert_receive {:telemetry, [:fastest_mcp, :task, :progress], %{current: 1},
                    %{server_name: ^server_name, task_id: ^task_id}}

    refute_received {:telemetry, [:fastest_mcp, :operation, :progress], _,
                     %{server_name: ^server_name}}
  end
end
