defmodule FastestMCP.AuthProviderParityTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error

  defmodule RaisingProvider do
    @behaviour FastestMCP.Auth

    def authenticate(_input, _context, _opts) do
      raise "simulated auth failure"
    end
  end

  test "static token provider authenticates valid tokens and enforces required scopes" do
    server_name = "static-token-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "valid-token" => %{
            client_id: "service-a",
            scopes: ["tools:call", "resources:read"],
            principal: %{"sub" => "service-a"}
          }
        },
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth, capabilities: ctx.capabilities}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "service-a"},
             auth: %{
               client_id: "service-a",
               provider: :static_token,
               scopes: ["tools:call", "resources:read"]
             },
             capabilities: ["tools:call", "resources:read"]
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer valid-token"}
             )

    scoped_server_name = server_name <> "-forbidden"

    scoped_server =
      FastestMCP.server(scoped_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "read-only" => %{client_id: "service-b", scopes: ["resources:read"]}
        },
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(scoped_server)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(scoped_server_name, "echo", %{},
          auth_input: %{"token" => "read-only"}
        )
      end

    assert error.code == :forbidden
    assert error.details[:missing_scopes] == ["tools:call"]
  end

  test "multi auth falls back across providers and ignores crashing providers" do
    server_name = "multi-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Multi,
        providers: [
          RaisingProvider,
          {FastestMCP.Auth.StaticToken,
           tokens: %{"fallback-token" => %{client_id: "fallback", scopes: ["tools:call"]}}}
        ]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"client_id" => "fallback"} ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer fallback-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "whoami", %{}, auth_input: %{"token" => "missing"})
      end

    assert error.code == :unauthorized
  end

  test "HTTP transport maps unauthorized and forbidden auth failures to auth-specific responses" do
    unauthorized_server_name =
      "http-auth-unauthorized-" <> Integer.to_string(System.unique_integer([:positive]))

    unauthorized_server =
      FastestMCP.server(unauthorized_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{"valid-token" => %{client_id: "service-a", scopes: ["tools:call"]}}
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(unauthorized_server)

    unauthorized_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: unauthorized_server_name)

    assert unauthorized_conn.status == 401
    assert get_resp_header(unauthorized_conn, "www-authenticate") != []
    assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(unauthorized_conn.resp_body)

    forbidden_server_name =
      "http-auth-forbidden-" <> Integer.to_string(System.unique_integer([:positive]))

    forbidden_server =
      FastestMCP.server(forbidden_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{"read-only" => %{client_id: "service-b", scopes: ["resources:read"]}},
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(forbidden_server)

    forbidden_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer read-only")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: forbidden_server_name)

    assert forbidden_conn.status == 403
    assert get_resp_header(forbidden_conn, "www-authenticate") == []
    assert %{"error" => %{"code" => "forbidden"}} = Jason.decode!(forbidden_conn.resp_body)
  end
end
