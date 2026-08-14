defmodule FastestMCP.AuthContractTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

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

  test "principal and authorization partitions never depend on raw credentials" do
    principal = {"https://issuer.example", "user-123"}

    assert FastestMCP.Auth.principal_fingerprint(principal) ==
             FastestMCP.Auth.principal_fingerprint(principal)

    left = %FastestMCP.Auth.Result{
      principal: principal,
      auth: %{token: "token-a", nested: %{client_secret: "secret-a"}, tenant: "acme"},
      capabilities: ["tools:call"],
      audiences: ["https://mcp.example/mcp"],
      scopes: ["tools:read"]
    }

    right = %{
      left
      | auth: %{
          token: "token-b",
          nested: %{client_secret: "secret-b"},
          tenant: "acme"
        }
    }

    assert FastestMCP.Auth.authorization_partition(left) ==
             FastestMCP.Auth.authorization_partition(right)

    changed_claim = %{right | auth: Map.put(right.auth, :tenant, "other")}

    refute FastestMCP.Auth.authorization_partition(left) ==
             FastestMCP.Auth.authorization_partition(changed_claim)
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

    auth_input = %{"authorization" => "Bearer valid-token"}

    {connection_id, _initialize_response} =
      ProtocolTest.initialize_stdio(server_name, auth_input: auth_input)

    stdio_response =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        2,
        "tools/call",
        %{"name" => "whoami"},
        auth_input: auth_input
      )

    assert stdio_response["jsonrpc"] == "2.0"
    assert stdio_response["result"]["structuredContent"]["principal"] == %{"sub" => "service-a"}

    ProtocolTest.initialize_session(server_name, "static-token-http-session")

    conn =
      ProtocolTest.http_request(
        server_name,
        "static-token-http-session",
        3,
        "tools/call",
        %{"name" => "whoami"},
        headers: [{"authorization", "Bearer valid-token"}]
      )

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "result" => %{"structuredContent" => %{"principal" => %{"sub" => "service-a"}}}
           } =
             JSON.decode!(conn.resp_body)
  end

  test "HTTP auth errors use bearer challenges without protected-resource metadata" do
    server_name = "auth-http-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{"valid-token" => %{client_id: "service-a", scopes: ["resources:read"]}},
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    ProtocolTest.initialize_session(server_name, "auth-error-session")

    unauthorized_conn =
      ProtocolTest.http_request(
        server_name,
        "auth-error-session",
        1,
        "tools/call",
        %{"name" => "echo"}
      )

    assert unauthorized_conn.status == 401
    assert [challenge] = get_resp_header(unauthorized_conn, "www-authenticate")
    assert String.starts_with?(challenge, "Bearer ")

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "error" => %{"data" => %{"fastestmcp" => %{"code" => "unauthorized"}}}
           } =
             JSON.decode!(unauthorized_conn.resp_body)

    forbidden_conn =
      ProtocolTest.http_request(
        server_name,
        "auth-error-session",
        2,
        "tools/call",
        %{"name" => "echo"},
        headers: [{"authorization", "Bearer valid-token"}]
      )

    assert forbidden_conn.status == 403

    assert get_resp_header(forbidden_conn, "www-authenticate") == [
             ~s(Bearer error="insufficient_scope", scope="tools:call", error_description="insufficient scope")
           ]

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{"data" => %{"fastestmcp" => %{"code" => "forbidden"}}}
           } =
             JSON.decode!(forbidden_conn.resp_body)
  end

  test "plain insufficient-scope challenges sort exact validated scope tokens" do
    error = %Error{
      code: :forbidden,
      message: "missing grants",
      details: %{missing_scopes: ["files:write", "files:admin", "files:write"]}
    }

    assert FastestMCP.Auth.validated_missing_scopes(error) == ["files:admin", "files:write"]

    assert FastestMCP.Auth.default_www_authenticate(error) ==
             ~s(Bearer error="insufficient_scope", scope="files:admin files:write", error_description="missing grants")

    invalid = %{error | details: %{missing_scopes: ["files:admin\n"]}}
    assert FastestMCP.Auth.validated_missing_scopes(invalid) == []
    refute FastestMCP.Auth.default_www_authenticate(invalid) =~ "scope="
  end

  test "component scope denial includes exact missing scopes without protected-resource metadata" do
    server_name =
      "auth-http-component-scope-" <> Integer.to_string(System.unique_integer([:positive]))

    authenticator = fn _input, _context ->
      {:ok,
       %{
         principal: {"https://auth.example.com", "user-1"},
         scopes: ["files:read"],
         audiences: ["https://mcp.example.com/mcp"]
       }}
    end

    server =
      FastestMCP.server(server_name, auth: authenticator)
      |> FastestMCP.add_tool("admin", fn -> "secret" end,
        auth: FastestMCP.Authorization.require_scopes(["files:write", "files:admin"])
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "tools/call",
        %{"name" => "admin", "arguments" => %{}},
        headers: [
          {"authorization", "Bearer verified-token"},
          {"mcp-name", "admin"}
        ]
      )

    assert response.status == 403

    assert get_resp_header(response, "www-authenticate") == [
             ~s(Bearer error="insufficient_scope", scope="files:admin files:write", error_description="access token does not grant the required scopes")
           ]

    assert get_in(JSON.decode!(response.resp_body), ["error", "data", "fastestmcp", "code"]) ==
             "forbidden"
  end

  test "from_assign supports direct auth input" do
    server_name = "auth-assign-direct-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(
        FastestMCP.Auth.from_assign(:current_user,
          principal: fn user -> %{"sub" => to_string(user.id)} end,
          capabilities: fn user -> user.scopes end,
          scopes: fn user -> user.scopes end,
          audiences: fn user -> user.audiences end,
          auth: fn user -> %{source: :phoenix, user_id: user.id} end
        )
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{
          principal: ctx.principal,
          auth: ctx.auth,
          capabilities: ctx.capabilities,
          verified_scopes: ctx.verified_scopes,
          verified_audiences: ctx.verified_audiences
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "123"},
             auth: %{source: :phoenix, user_id: 123},
             capabilities: ["tools:call"],
             verified_scopes: ["tools:call"],
             verified_audiences: ["https://mcp.example/mcp"]
           } ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{
                 "assigns" => %{
                   "current_user" => %{
                     id: 123,
                     scopes: ["tools:call"],
                     audiences: ["https://mcp.example/mcp"]
                   }
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
    ProtocolTest.initialize_session(server_name, "auth-assign-session")

    conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!(ProtocolTest.jsonrpc_request(1, "tools/call", %{"name" => "whoami"}))
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-session-id", "auth-assign-session")
      |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> assign(:current_user, %{id: 456, scopes: ["tools:call"]})
      |> assign(:admin_secret, "not copied")
      |> StreamableHTTP.call(
        server_name: server_name,
        auth_assigns: [:current_user],
        allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
        json_response: true
      )

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "structuredContent" => %{
                 "principal" => %{"sub" => "456"},
                 "auth" => %{"seen_assigns" => ["current_user"]},
                 "capabilities" => ["tools:call"],
                 "metadata_has_assigns" => false
               }
             }
           } = JSON.decode!(conn.resp_body)

    missing_conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!(ProtocolTest.jsonrpc_request(2, "tools/call", %{"name" => "whoami"}))
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-session-id", "auth-assign-session")
      |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
      |> StreamableHTTP.call(
        server_name: server_name,
        auth_assigns: [:current_user],
        allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
        json_response: true
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

    auth_input = %{"token" => "secret-token"}

    {connection_id, _initialize_response} =
      ProtocolTest.initialize_stdio(server_name, auth_input: auth_input)

    stdio_response =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        2,
        "tools/call",
        %{"name" => "whoami"},
        auth_input: auth_input
      )

    assert stdio_response["jsonrpc"] == "2.0"
    assert stdio_response["result"]["structuredContent"] == %{"sub" => "user-123"}

    ProtocolTest.initialize_session(server_name, "auth-http-session")

    conn =
      ProtocolTest.http_request(
        server_name,
        "auth-http-session",
        3,
        "tools/call",
        %{"name" => "whoami"},
        headers: [{"authorization", "Bearer secret-token"}]
      )

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "result" => %{"structuredContent" => %{"sub" => "user-123"}}
           } =
             JSON.decode!(conn.resp_body)
  end
end
