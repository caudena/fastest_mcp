defmodule FastestMCP.AuthContractTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error

  defmodule StaticProvider do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, opts) do
      expected_token = Map.get(opts, :token, "secret-token")

      if extract_token(input) == expected_token do
        {:ok,
         %{
           principal: %{"sub" => "user-123"},
           auth: %{provider: :static, token: expected_token},
           capabilities: ["tools:call", "resources:read"]
         }}
      else
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
      end
    end

    defp extract_token(%{"token" => token}), do: token
    defp extract_token(%{"authorization" => "Bearer " <> token}), do: token
    defp extract_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: token
    defp extract_token(_input), do: nil
  end

  defmodule InvalidProvider do
  end

  test "server auth is declarative and invalid providers are rejected early" do
    server =
      FastestMCP.server(
        "auth-config-" <> Integer.to_string(System.unique_integer([:positive])),
        auth: {StaticProvider, token: "secret-token"}
      )

    assert %FastestMCP.Auth{provider: StaticProvider, options: %{token: "secret-token"}} =
             server.auth

    assert_raise ArgumentError, ~r/must export authenticate\/3/, fn ->
      FastestMCP.server("invalid-auth-" <> Integer.to_string(System.unique_integer([:positive])))
      |> FastestMCP.add_auth(InvalidProvider)
    end
  end

  test "module authenticator enriches context for direct calls and rejects invalid credentials" do
    server_name = "auth-direct-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{
          principal: ctx.principal,
          auth: ctx.auth,
          capabilities: ctx.capabilities
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "user-123"},
             auth: %{provider: :static, token: "secret-token"},
             capabilities: ["tools:call", "resources:read"]
           } ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"token" => "secret-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "whoami", %{}, auth_input: %{"token" => "wrong"})
      end

    assert error.code == :unauthorized
  end

  test "function authenticator works for direct calls" do
    server_name = "auth-function-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn input, _ctx ->
        if input["token"] == "function-token" do
          {:ok,
           %{
             principal: %{"sub" => "function-user"},
             auth: %{provider: :function},
             capabilities: ["tools:call"]
           }}
        else
          {:error, :unauthorized}
        end
      end)
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{
          principal: ctx.principal,
          auth: ctx.auth,
          capabilities: ctx.capabilities
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "function-user"},
             auth: %{provider: :function},
             capabilities: ["tools:call"]
           } ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"token" => "function-token"}
             )
  end

  test "static token auth works for direct, stdio, and HTTP calls" do
    server_name = "auth-static-token-" <> Integer.to_string(System.unique_integer([:positive]))

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

    stdio_response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "whoami",
          "auth_input" => %{"token" => "valid-token"}
        }
      })

    assert stdio_response["ok"] == true
    assert stdio_response["result"]["structuredContent"]["principal"] == %{"sub" => "service-a"}

    conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-token")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert %{"structuredContent" => %{"principal" => %{"sub" => "service-a"}}} =
             JSON.decode!(conn.resp_body)
  end

  test "HTTP auth errors use the plain bearer challenge" do
    server_name = "auth-http-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{"valid-token" => %{client_id: "service-a", scopes: ["resources:read"]}},
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    unauthorized_conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert unauthorized_conn.status == 401
    assert [challenge] = get_resp_header(unauthorized_conn, "www-authenticate")
    assert String.starts_with?(challenge, "Bearer ")

    assert %{"error" => %{"code" => "unauthorized"}} =
             JSON.decode!(unauthorized_conn.resp_body)

    forbidden_conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-token")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert forbidden_conn.status == 403
    assert get_resp_header(forbidden_conn, "www-authenticate") == []

    assert %{"error" => %{"code" => "forbidden"}} =
             JSON.decode!(forbidden_conn.resp_body)
  end

  test "from_assign supports direct auth input" do
    server_name = "auth-assign-direct-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(
        FastestMCP.Auth.from_assign(:current_user,
          principal: fn user -> %{"sub" => to_string(user.id)} end,
          capabilities: fn user -> user.scopes end,
          auth: fn user -> %{source: :phoenix, user_id: user.id} end
        )
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth, capabilities: ctx.capabilities}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "123"},
             auth: %{source: :phoenix, user_id: 123},
             capabilities: ["tools:call"]
           } ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{
                 "assigns" => %{
                   "current_user" => %{id: 123, scopes: ["tools:call"]}
                 }
               }
             )
  end

  test "HTTP auth_assigns copies only selected Plug assigns into auth input" do
    server_name = "auth-assign-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn input, _ctx ->
        assigns = Map.get(input, "assigns", %{})

        case Map.fetch(assigns, "current_user") do
          {:ok, user} ->
            {:ok,
             %{
               principal: %{"sub" => to_string(user.id)},
               auth: %{seen_assigns: Map.keys(assigns) |> Enum.sort()},
               capabilities: user.scopes
             }}

          :error ->
            {:error, :unauthorized}
        end
      end)
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{
          principal: ctx.principal,
          auth: ctx.auth,
          capabilities: ctx.capabilities,
          metadata_has_assigns:
            Map.has_key?(ctx.request_metadata, :assigns) or
              Map.has_key?(ctx.request_metadata, "assigns")
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> assign(:current_user, %{id: 456, scopes: ["tools:call"]})
      |> assign(:admin_secret, "not copied")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        auth_assigns: [:current_user]
      )

    assert conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{"sub" => "456"},
               "auth" => %{"seen_assigns" => ["current_user"]},
               "capabilities" => ["tools:call"],
               "metadata_has_assigns" => false
             }
           } = JSON.decode!(conn.resp_body)

    missing_conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        auth_assigns: [:current_user]
      )

    assert missing_conn.status == 401
  end

  test "stdio and HTTP transports pass auth input into the shared authenticator" do
    server_name = "auth-transport-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    stdio_response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "whoami",
          "auth_input" => %{"token" => "secret-token"}
        }
      })

    assert stdio_response["ok"] == true
    assert stdio_response["result"]["structuredContent"] == %{"sub" => "user-123"}

    conn =
      conn(:post, "/mcp/tools/call", JSON.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret-token")
      |> put_req_header("x-fastestmcp-session", "auth-http-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert %{"structuredContent" => %{"sub" => "user-123"}} =
             JSON.decode!(conn.resp_body)
  end
end
