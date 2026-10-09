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
end
