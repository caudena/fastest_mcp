defmodule FastestMCP.AuthContractTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog
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

  defmodule RejectingProvider do
    @behaviour FastestMCP.Auth

    def authenticate(_input, _context, _opts), do: {:error, :unauthorized}
  end

  # Fails as `opts.how` says, with the input's token in the exception's
  # message, its stack trace, or the value it throws, exits with, or returns.
  defmodule FailingProvider do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, %{how: :raise}), do: Map.fetch!(input, :user)

    def authenticate(input, _context, %{how: :bif}),
      do: :erlang.binary_to_existing_atom(input["authorization"], :utf8)

    def authenticate(input, _context, %{how: :throw}), do: throw({:token, input["authorization"]})
    def authenticate(input, _context, %{how: :exit}), do: exit({:token, input["authorization"]})
    def authenticate(input, _context, %{how: :return}), do: {:token, input["authorization"]}
  end

  # A function authenticator that raises, for the name the log gives it.
  def failing_authenticate(input, _context), do: Map.fetch!(input, :user)

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

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
    |> FastestMCP.add_tool("whoami", fn _args, ctx ->
      %{
        principal: ctx.principal,
        auth: ctx.auth,
        capabilities: ctx.capabilities
      }
    end)
    |> start_server!()

    assert %{
             principal: %{"sub" => "user-123"},
             auth: %{provider: :static, token: "secret-token"},
             capabilities: ["tools:call", "resources:read"]
           } ==
             FastestMCP.call_tool!(server_name, "whoami", %{},
               auth_input: %{"token" => "secret-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_name, "whoami", %{}, auth_input: %{"token" => "wrong"})
      end

    assert error.code == :unauthorized
  end

  test "function authenticator works for direct calls" do
    server_name = "auth-function-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    assert %{
             principal: %{"sub" => "function-user"},
             auth: %{provider: :function},
             capabilities: ["tools:call"]
           } ==
             FastestMCP.call_tool!(server_name, "whoami", %{},
               auth_input: %{"token" => "function-token"}
             )
  end

  test "static token auth works for direct, stdio, and HTTP calls" do
    server_name = "auth-static-token-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    assert %{
             principal: %{"sub" => "service-a"},
             auth: %{
               client_id: "service-a",
               provider: :static_token,
               scopes: ["tools:call", "resources:read"]
             },
             capabilities: ["tools:call", "resources:read"]
           } =
             FastestMCP.call_tool!(server_name, "whoami", %{},
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

  @tag :capture_log
  test "an authenticator that crashes is masked like a handler crash, and its input stays hidden" do
    token = "Bearer token-in-the-auth-input"
    crash = fn input, _ctx -> Map.fetch!(input, :user) end

    for masked? <- [false, true] do
      server_name = unique_name("auth-crash")

      FastestMCP.server(server_name, mask_error_details: masked?)
      |> FastestMCP.add_auth(crash)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()

      # In process the error is whole, its cause included, for logs and spans.
      assert {:error,
              %Error{code: :internal_error, message: message, cause: {%KeyError{}, [_ | _]}}} =
               FastestMCP.call_tool(server_name, "echo", %{},
                 auth_input: %{"authorization" => token}
               )

      refute message =~ "token-in-the-auth-input"

      http =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "echo"},
          headers: [{"authorization", token}, {"mcp-name", "echo"}]
        )

      stdio =
        ProtocolTest.modern_stdio_request(server_name, 2, "tools/call", %{"name" => "echo"},
          auth_input: %{"authorization" => token}
        )

      for %{"error" => error} = body <- [JSON.decode!(http.resp_body), stdio] do
        refute inspect(body) =~ "token-in-the-auth-input"

        if masked? do
          assert %{"message" => "authentication failed", "data" => %{"fastestmcp" => fastestmcp}} =
                   error

          refute Map.has_key?(fastestmcp, "details")
        else
          assert %{
                   "message" => "authenticator failed",
                   "data" => %{"fastestmcp" => %{"details" => %{"kind" => "KeyError"}}}
                 } = error
        end
      end
    end
  end

  @tag :capture_log
  test "over HTTP, an authenticator that crashes gets 500 on both protocol versions" do
    token = "Bearer token-in-the-auth-input"

    for masked? <- [false, true] do
      server_name = unique_name("auth-crash-http")

      FastestMCP.server(server_name, mask_error_details: masked?)
      |> FastestMCP.add_auth(fn input, _ctx -> Map.fetch!(input, :user) end)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()

      modern =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "echo"},
          headers: [{"authorization", token}, {"mcp-name", "echo"}]
        )

      initialize = ProtocolTest.jsonrpc_request(2, "initialize", ProtocolTest.initialize_params())

      legacy =
        ProtocolTest.http_post(server_name, nil, initialize, headers: [{"authorization", token}])

      for conn <- [modern, legacy] do
        assert conn.status == 500

        assert %{"error" => %{"code" => -32_603, "message" => message}} =
                 JSON.decode!(conn.resp_body)

        refute conn.resp_body =~ "token-in-the-auth-input"
        refute conn.resp_body =~ "not found"

        if masked?,
          do: assert(message == "authentication failed"),
          else: assert(message == "authenticator failed")
      end
    end
  end

  test "over HTTP, an authenticator's error gets the status of its code" do
    server_name = unique_name("auth-error-status")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn %{"headers" => %{"x-code" => code}}, _ctx ->
      {:error, {String.to_existing_atom(code), "token service says #{code}"}}
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    for {code, status} <- [rate_limited: 429, overloaded: 503, timeout: 504, invalid_token: 400] do
      conn =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "echo"},
          headers: [{"x-code", code}, {"mcp-name", "echo"}]
        )

      assert {conn.status, JSON.decode!(conn.resp_body)["error"]["message"]} ==
               {status, "token service says #{code}"}

      if code == :overloaded, do: assert(get_resp_header(conn, "retry-after") == ["1"])
    end
  end

  test "ctx.authenticated is true only when an authenticator accepted the request" do
    tool = fn _args, ctx -> %{authenticated: ctx.authenticated} end
    open_name = unique_name("authenticated-open")
    protected_name = unique_name("authenticated-protected")

    FastestMCP.server(open_name)
    |> FastestMCP.add_tool("authenticated", tool)
    |> start_server!()

    FastestMCP.server(protected_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"valid-token" => %{client_id: "service-a"}}
    )
    |> FastestMCP.add_tool("authenticated", tool)
    |> start_server!()

    call = %{"name" => "authenticated"}
    token = [{"authorization", "Bearer valid-token"}]

    for {server_name, headers, expected} <- [
          {open_name, [], false},
          {protected_name, token, true}
        ] do
      modern =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", call,
          headers: [{"mcp-name", "authenticated"} | headers]
        )

      assert %{"result" => %{"structuredContent" => %{"authenticated" => ^expected}}} =
               JSON.decode!(modern.resp_body)

      {session_id, _initialize, _initialized} =
        ProtocolTest.initialize_http(server_name, headers: headers)

      legacy =
        ProtocolTest.http_request(server_name, session_id, 2, "tools/call", call,
          headers: headers
        )

      assert %{"result" => %{"structuredContent" => %{"authenticated" => ^expected}}} =
               JSON.decode!(legacy.resp_body)
    end

    auth_input = %{"authorization" => "Bearer valid-token"}

    for {server_name, opts, expected} <- [
          {open_name, [], false},
          {protected_name, [auth_input: auth_input], true}
        ] do
      {connection_id, _initialize} = ProtocolTest.initialize_stdio(server_name, opts)

      assert %{"result" => %{"structuredContent" => %{"authenticated" => ^expected}}} =
               ProtocolTest.stdio_request(server_name, connection_id, 2, "tools/call", call, opts)

      assert %{authenticated: ^expected} =
               FastestMCP.call_tool!(server_name, "authenticated", %{}, opts)
    end
  end

  test "HTTP auth errors use bearer challenges without protected-resource metadata" do
    server_name = "auth-http-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"valid-token" => %{client_id: "service-a", scopes: ["resources:read"]}},
      required_scopes: ["tools:call"]
    )
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

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
    assert get_resp_header(unauthorized_conn, "www-authenticate") == ["Bearer"]

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

  test "a request without credentials gets a challenge without an error code or assign name" do
    server_name = unique_name("auth-no-credentials")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.from_assign(:current_scope))
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    missing = ProtocolTest.modern_http_request(server_name, 1, "tools/list")

    assert missing.status == 401
    assert get_resp_header(missing, "www-authenticate") == ["Bearer"]
    refute missing.resp_body =~ "current_scope"

    assert get_in(JSON.decode!(missing.resp_body), ["error", "message"]) ==
             "missing or invalid credentials"

    # The token was sent, and the plug that would assign the caller rejected it.
    rejected =
      ProtocolTest.modern_http_request(server_name, 2, "tools/list", %{},
        headers: [{"authorization", "Bearer expired-token"}]
      )

    assert rejected.status == 401

    assert get_resp_header(rejected, "www-authenticate") == [
             ~s(Bearer error="invalid_token", error_description="missing or invalid credentials")
           ]

    assert {:error, %Error{code: :unauthorized, message: "missing or invalid credentials"}} =
             FastestMCP.list_tools(server_name)
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

    multiline = %Error{code: :unauthorized, message: ~s(bad "token"\r\nInjected: header)}

    assert FastestMCP.Auth.default_www_authenticate(multiline) ==
             ~s(Bearer error="invalid_token", error_description="bad \\"token\\"  Injected: header")
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

    FastestMCP.server(server_name, auth: authenticator)
    |> FastestMCP.add_tool("admin", fn -> "secret" end,
      auth: FastestMCP.Authorization.require_scopes(["files:write", "files:admin"])
    )
    |> start_server!()

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
    |> start_server!()

    assert %{
             principal: %{"sub" => "123"},
             auth: %{source: :phoenix, user_id: 123},
             capabilities: ["tools:call"],
             verified_scopes: ["tools:call"],
             verified_audiences: ["https://mcp.example/mcp"]
           } ==
             FastestMCP.call_tool!(server_name, "whoami", %{},
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

    start_server!(server)
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

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
    |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)
    |> start_server!()

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

  test "over stdio and in process, the handshake authenticates only the credentials it carries" do
    server_name = unique_name("auth-discover")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn _input, _ctx -> {:error, :unauthorized} end)
    |> FastestMCP.add_tool("ping", fn _args, _ctx -> "pong" end)
    |> start_server!()

    assert %{"result" => %{"supportedVersions" => [_ | _]}} =
             ProtocolTest.modern_stdio_request(server_name, 1, "server/discover")

    assert %{"error" => %{"message" => "unauthorized"}} =
             ProtocolTest.modern_stdio_request(server_name, 2, "tools/call", %{"name" => "ping"})

    client = connect!({:in_process, server_name})
    assert FastestMCP.Client.info!(client).protocol_version == "2026-07-28"

    assert {:error, %Error{code: :unauthorized, message: "unauthorized"}} =
             FastestMCP.Client.call_tool(client, "ping", %{})

    # Credentials that the handshake carries are authenticated.
    assert %{"error" => %{"message" => "unauthorized"}} =
             ProtocolTest.modern_stdio_request(server_name, 3, "server/discover", %{},
               auth_input: %{"token" => "expired"}
             )

    # Over HTTP, every request is authenticated.
    assert ProtocolTest.modern_http_request(server_name, 4, "server/discover").status == 401
  end

  test "the handshake offers completions for a prompt only some callers may use" do
    server_name = unique_name("auth-completions")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn input, _ctx ->
      if input["token"] == "reader",
        do: {:ok, %{principal: "reader", scopes: ["notes:read"]}},
        else: {:error, :unauthorized}
    end)
    |> FastestMCP.add_prompt("summarize", fn %{"topic" => topic}, _ctx -> "About #{topic}" end,
      arguments: [%{name: "topic", required: true, completion: ["release", "roadmap"]}],
      authorization: [FastestMCP.Authorization.require_scopes(["notes:read"])]
    )
    |> start_server!()

    for version <- ["2026-07-28", "2025-11-25"] do
      client =
        connect!({:in_process, server_name},
          protocol_version: version,
          auth_input: %{"token" => "reader"}
        )

      assert %{"completions" => %{}} = FastestMCP.Client.info!(client).capabilities

      assert {:ok, %{"values" => ["release", "roadmap"]}} =
               FastestMCP.Client.complete(
                 client,
                 %{"type" => "ref/prompt", "name" => "summarize"},
                 %{"name" => "topic", "value" => "r"}
               )
    end
  end

  @tag :capture_log
  test "client-visible authentication errors name no authenticator module" do
    outcomes = [
      {fn _input, _ctx -> {:error, :unauthorized} end, 401, "unauthorized"},
      {fn _input, _ctx -> {:error, :forbidden} end, 403, "forbidden"},
      {fn _input, _ctx -> {:error, {:unauthorized, "token expired"}} end, 401, "token expired"},
      {fn _input, _ctx -> {:error, :token_service_down} end, 500, "authenticator failed"},
      {fn _input, _ctx -> raise "token service down" end, 500, "authenticator failed"},
      {RejectingProvider, 401, "unauthorized"}
    ]

    for {authenticator, status, message} <- outcomes do
      server_name = unique_name("auth-error-names")

      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(authenticator)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()

      assert {:error, %Error{message: ^message} = error} =
               FastestMCP.call_tool(server_name, "echo", %{})

      refute Map.has_key?(error.details, :provider)

      conn =
        ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "echo"},
          headers: [{"mcp-name", "echo"}]
        )

      assert conn.status == status
      assert %{"error" => %{"message" => ^message}} = JSON.decode!(conn.resp_body)
      refute conn.resp_body =~ "FastestMCP.Auth"
      refute conn.resp_body =~ "RejectingProvider"
    end
  end

  @tag :capture_log
  test "an authenticator that throws or exits fails as one that raises" do
    attach_telemetry([[:fastest_mcp, :auth, :exception]])

    for authenticator <- [
          fn _input, _ctx -> throw(:token_service_down) end,
          fn _input, _ctx -> exit(:token_service_down) end
        ] do
      server_name = unique_name("auth-throw-exit")

      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(authenticator)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()

      assert {:error,
              %Error{
                code: :internal_error,
                message: "authenticator failed",
                details: %{kind: "ErlangError"},
                cause: {%ErlangError{original: {_kind, :token_service_down}}, [_ | _]}
              }} = FastestMCP.call_tool(server_name, "echo", %{})

      stdio = ProtocolTest.modern_stdio_request(server_name, 1, "tools/call", %{"name" => "echo"})

      http =
        ProtocolTest.modern_http_request(server_name, 2, "tools/call", %{"name" => "echo"},
          headers: [{"mcp-name", "echo"}]
        )

      assert http.status == 500

      for %{"error" => error} <- [stdio, JSON.decode!(http.resp_body)] do
        assert %{
                 "code" => -32_603,
                 "message" => "authenticator failed",
                 "data" => %{"fastestmcp" => %{"details" => %{"kind" => "ErlangError"}}}
               } = error
      end

      # In process, over stdio, and over HTTP, the authentication ends with
      # its exception event.
      for _request <- 1..3 do
        assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], _measurements,
                        %{server_name: ^server_name, kind: :error, reason: %ErlangError{}}}
      end
    end
  end

  test "a list request runs the authenticator once, on every transport" do
    test_pid = self()
    server_name = unique_name("auth-once")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn input, _ctx ->
      send(test_pid, :authenticated)

      if input["authorization"] == "Bearer list-token",
        do: {:ok, %{principal: %{"sub" => "lister"}}},
        else: {:error, :unauthorized}
    end)
    |> FastestMCP.add_tool("export", fn _args, _ctx -> "done" end, task: true)
    |> FastestMCP.add_prompt("greet", fn _args, _ctx -> "hello" end)
    |> FastestMCP.add_resource("notes://all", fn _args, _ctx -> "notes" end)
    |> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx -> id end)
    |> start_server!()

    auth_input = %{"authorization" => "Bearer list-token"}

    lists = [
      &FastestMCP.Client.list_tools/1,
      &FastestMCP.Client.list_prompts/1,
      &FastestMCP.Client.list_resources/1,
      &FastestMCP.Client.list_resource_templates/1
    ]

    for version <- ["2026-07-28", "2025-11-25"] do
      client =
        connect!({:in_process, server_name}, protocol_version: version, auth_input: auth_input)

      authentications()

      lists =
        if version == "2025-11-25", do: [(&FastestMCP.Client.list_tasks/1) | lists], else: lists

      for list <- lists do
        assert {:ok, _page} = list.(client)
        assert authentications() == 1
      end
    end

    assert %{"result" => %{"tools" => [_]}} =
             ProtocolTest.modern_stdio_request(server_name, 1, "tools/list", %{},
               auth_input: auth_input
             )

    assert authentications() == 1

    conn =
      ProtocolTest.modern_http_request(server_name, 2, "tools/list", %{},
        headers: [{"authorization", "Bearer list-token"}]
      )

    assert conn.status == 200
    assert authentications() == 1

    # With MCP Apps, the UI resource a listed tool links to is looked up
    # under the identity the list authenticated.
    apps = FastestMCP.Protocol.Extensions.apps()
    apps_server = unique_name("auth-once-apps")

    FastestMCP.server(apps_server, extensions: %{apps => %{}})
    |> FastestMCP.add_auth(fn _input, _ctx ->
      send(test_pid, :authenticated)
      {:ok, %{principal: %{"sub" => "lister"}}}
    end)
    |> FastestMCP.add_tool("widget", fn _args, _ctx -> "done" end,
      meta: FastestMCP.Apps.tool_meta("ui://widgets/one")
    )
    |> FastestMCP.add_resource(
      "ui://widgets/one",
      fn _args, _ctx -> FastestMCP.Apps.result("ui://widgets/one", "<html></html>") end,
      mime_type: FastestMCP.Apps.mime_type()
    )
    |> start_server!()

    client =
      connect!({:in_process, apps_server},
        extensions: %{apps => FastestMCP.Apps.client_settings()}
      )

    authentications()
    assert {:ok, %{items: [_widget]}} = FastestMCP.Client.list_tools(client)
    assert authentications() == 1

    # A list that fails authentication emits the authentication events.
    attach_telemetry([[:fastest_mcp, :auth, :exception]])

    assert %{"error" => %{"message" => "unauthorized"}} =
             ProtocolTest.modern_stdio_request(server_name, 3, "tools/list")

    assert authentications() == 1

    assert_receive {:telemetry, [:fastest_mcp, :auth, :exception], _measurements,
                    %{server_name: ^server_name, method: "tools/list"}}
  end

  test "a request with more than one Authorization header gets 400 before authentication" do
    test_pid = self()
    server_name = unique_name("auth-repeated-authorization")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn input, _ctx ->
      send(test_pid, {:authenticated, input["authorization"]})

      if input["authorization"] == "Bearer valid-token",
        do: {:ok, %{principal: %{"sub" => "user-1"}}},
        else: {:error, :unauthorized}
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    valid = {"authorization", "Bearer valid-token"}
    junk = {"authorization", "Bearer junk"}

    {session_id, _initialize, _initialized} =
      ProtocolTest.initialize_http(server_name, headers: [valid])

    assert_received {:authenticated, "Bearer valid-token"}
    assert_received {:authenticated, "Bearer valid-token"}

    session = fn conn ->
      conn
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
    end

    post = fn payload ->
      conn(:post, "/mcp", JSON.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
    end

    modern =
      ProtocolTest.modern_request(1, "tools/call", %{"name" => "echo"})
      |> post.()
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "echo")

    initialize =
      post.(ProtocolTest.jsonrpc_request(2, "initialize", ProtocolTest.initialize_params()))

    call =
      ProtocolTest.jsonrpc_request(3, "tools/call", %{"name" => "echo"}) |> post.() |> session.()

    stream = conn(:get, "/mcp") |> put_req_header("accept", "text/event-stream") |> session.()
    delete = conn(:delete, "/mcp") |> session.()

    # A junk token before a valid one, or after it: neither reaches the
    # authenticator, on either protocol version.
    for {conn, headers} <- [
          {modern, [junk, valid]},
          {initialize, [junk, valid]},
          {call, [valid, junk]},
          {stream, [valid, junk]},
          {delete, [valid, junk]}
        ] do
      response =
        conn
        |> prepend_req_headers(headers)
        |> Map.put(:host, "localhost")
        |> StreamableHTTP.call(server_name: server_name, json_response: true)

      assert response.status == 400

      assert get_resp_header(response, "www-authenticate") == [
               ~s(Bearer error="invalid_request", error_description="request has more than one Authorization header")
             ]
    end

    refute_received {:authenticated, _authorization}

    # Through a listener, which keeps repeated headers apart.
    %{port: port} = start_http!(server_name)
    body = JSON.encode!(ProtocolTest.modern_request(4, "tools/list"))

    response =
      raw_http_request(port, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\n",
        "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/list\r\n",
        "Authorization: Bearer junk\r\nAuthorization: Bearer valid-token\r\n",
        "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
        body
      ])

    assert response.status == 400
    assert response.headers["www-authenticate"] =~ ~s(error="invalid_request")
    refute_received {:authenticated, _authorization}
  end

  test "realm: comes first in every challenge of the route" do
    server_name = unique_name("auth-realm")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{"reader-token" => %{client_id: "reader", scopes: ["notes:read"]}}
    )
    |> FastestMCP.add_tool("delete_notes", fn _args, _ctx -> "deleted" end,
      authorization: FastestMCP.Authorization.require_scopes("notes:write")
    )
    |> start_server!()

    # The realm is quoted and escaped as an HTTP quoted-string.
    opts = [realm: ~s(notes "private" mcp)]
    realm = ~s(realm="notes \\"private\\" mcp")
    delete = %{"name" => "delete_notes"}

    missing = ProtocolTest.modern_http_request(server_name, 1, "tools/list", %{}, opts)

    invalid =
      ProtocolTest.modern_http_request(
        server_name,
        2,
        "tools/list",
        %{},
        [headers: [{"authorization", "Bearer unknown-token"}]] ++ opts
      )

    forbidden =
      ProtocolTest.modern_http_request(
        server_name,
        3,
        "tools/call",
        delete,
        [headers: [{"authorization", "Bearer reader-token"}, {"mcp-name", "delete_notes"}]] ++
          opts
      )

    repeated =
      ProtocolTest.modern_request(4, "tools/list")
      |> then(&conn(:post, "/mcp", JSON.encode!(&1)))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/list")
      |> prepend_req_headers([{"authorization", "Bearer a"}, {"authorization", "Bearer b"}])
      |> Map.put(:host, "localhost")
      |> StreamableHTTP.call([server_name: server_name] ++ opts)

    assert Enum.map(
             [missing, invalid, forbidden, repeated],
             &get_resp_header(&1, "www-authenticate")
           ) ==
             [
               ["Bearer #{realm}"],
               [
                 ~s(Bearer #{realm}, error="invalid_token", error_description="invalid credentials")
               ],
               [
                 ~s(Bearer #{realm}, error="insufficient_scope", scope="notes:write", error_description="access token does not grant the required scopes")
               ],
               [
                 ~s(Bearer #{realm}, error="invalid_request", error_description="request has more than one Authorization header")
               ]
             ]

    # A realm is a non-empty string of visible ASCII characters and spaces.
    for realm <- ["", "line\nbreak", "tab\there", :notes, "café"] do
      assert_raise ArgumentError, ~r/realm must be/, fn ->
        FastestMCP.http_app(server_name, realm: realm)
      end
    end
  end

  test "over HTTP, the authenticator's input carries the JSON-RPC message of the request" do
    test_pid = self()
    server_name = unique_name("auth-request-input")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(fn input, _ctx ->
      send(test_pid, {:auth_input, input})
      {:ok, %{principal: %{"sub" => "user-1"}}}
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    call = %{"name" => "echo", "arguments" => %{"text" => "hi"}}

    modern =
      ProtocolTest.modern_http_request(server_name, 7, "tools/call", call,
        headers: [{"mcp-name", "echo"}]
      )

    assert modern.status == 200

    assert_received {:auth_input,
                     %{
                       "request" => %{
                         "jsonrpc" => "2.0",
                         "id" => 7,
                         "method" => "tools/call",
                         "params" => %{"name" => "echo", "arguments" => %{"text" => "hi"}}
                       }
                     }}

    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert_received {:auth_input, %{"request" => %{"id" => 1, "method" => "initialize"}}}

    assert_received {:auth_input, %{"request" => %{"method" => "notifications/initialized"}}}

    # A DELETE carries no JSON-RPC message.
    deleted =
      conn(:delete, "/mcp")
      |> Map.put(:host, "localhost")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> StreamableHTTP.call(server_name: server_name)

    assert deleted.status == 204
    assert_received {:auth_input, %{"request" => nil}}

    # In process, the input is the one the call passes.
    FastestMCP.call_tool!(server_name, "echo", %{}, auth_input: %{"token" => "in-process"})
    assert_received {:auth_input, %{"token" => "in-process"} = input}
    refute Map.has_key?(input, "request")
  end

  @tag :capture_log
  test "an authenticator that fails with an internal error is logged once, without its message or arguments" do
    # Unique, so that no other test logs it.
    secret = unique_name("token-in-the-auth-input")
    token = "Bearer " <> secret
    provider = inspect(FailingProvider)

    for {how, outcome} <- [
          raise: "raised KeyError",
          bif: "raised ArgumentError",
          throw: "threw",
          exit: "exited",
          return: "returned neither {:ok, result} nor {:error, reason}"
        ] do
      server_name = unique_name("auth-failure-log")

      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FailingProvider, how: how)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()

      requests = [
        fn ->
          FastestMCP.call_tool(server_name, "echo", %{}, auth_input: %{"authorization" => token})
        end,
        fn ->
          ProtocolTest.modern_stdio_request(server_name, 1, "tools/call", %{"name" => "echo"},
            auth_input: %{"authorization" => token}
          )
        end,
        fn ->
          ProtocolTest.modern_http_request(server_name, 2, "tools/call", %{"name" => "echo"},
            headers: [{"authorization", token}, {"mcp-name", "echo"}]
          )
        end
      ]

      for request <- requests do
        log = capture_log(request)

        # One line names the authenticator and what it did; other tests may
        # log at the same time.
        assert [_line] =
                 Regex.scan(
                   ~r/FastestMCP authenticator #{provider} #{Regex.escape(outcome)}/,
                   log
                 )

        refute log =~ secret

        if how in [:raise, :bif],
          do: assert(log =~ "#{provider}.authenticate/3")

        if how == :bif, do: assert(log =~ ":erlang.binary_to_existing_atom/2")
      end
    end

    # A function authenticator is named by its function.
    server_name = unique_name("auth-failure-log-function")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(&__MODULE__.failing_authenticate/2)
    |> start_server!()

    log = capture_log(fn -> FastestMCP.list_tools(server_name, auth_input: %{"a" => token}) end)

    assert log =~
             "FastestMCP authenticator FastestMCP.AuthContractTest.failing_authenticate/2 raised KeyError"

    refute log =~ secret
  end

  # Sends one HTTP/1.1 request to the loopback listener on `port` and returns
  # the status and headers of the response.
  defp raw_http_request(port, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    response = receive_until_closed(socket, "")
    [head, _body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers}
  end

  defp receive_until_closed(socket, received) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_until_closed(socket, received <> data)
      {:error, :closed} -> received
    end
  end

  # The number of `:authenticated` messages in the mailbox, which it empties.
  defp authentications(count \\ 0) do
    receive do
      :authenticated -> authentications(count + 1)
    after
      0 -> count
    end
  end
end
