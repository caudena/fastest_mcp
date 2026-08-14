defmodule FastestMCP.ProtectedResourceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth
  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Authorization
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.WellKnownHTTP

  test "serializes RFC 9728 metadata at the path-derived URI" do
    protected_resource = protected_resource()

    assert ProtectedResource.metadata_path(protected_resource) ==
             "/.well-known/oauth-protected-resource/public/mcp"

    assert ProtectedResource.metadata_url(protected_resource) ==
             "https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp"

    assert ProtectedResource.metadata(protected_resource) == %{
             "authorization_servers" => ["https://auth.example.com/tenant"],
             "bearer_methods_supported" => ["header"],
             "resource" => "https://mcp.example.com/public/mcp",
             "resource_name" => "Example MCP",
             "scopes_supported" => ["files:read"],
             "x-service" => "documents"
           }
  end

  test "builds a discoverable, request-specific Bearer challenge" do
    challenge =
      ProtectedResource.www_authenticate(protected_resource(),
        scopes: ["files:read"],
        error: %Error{code: :unauthorized, message: "expired"},
        error_description: "expired\ncredential"
      )

    assert challenge ==
             ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp", scope="files:read", error="invalid_token", error_description="expired credential")
  end

  test "verified audience and scope evidence survives the context handoff" do
    assert {:ok, context} =
             Context.build(unique_name("verified-context"), state_scope: :request)

    auth_result = %AuthResult{
      principal: %{"sub" => "user-1"},
      auth: %{provider: :test},
      capabilities: ["resources:read"],
      audiences: ["https://mcp.example.com/public/mcp"],
      scopes: ["files:read"]
    }

    context = Context.put_auth_result(context, auth_result)
    normalized = Auth.result_from_context(context)

    assert normalized.principal == auth_result.principal
    assert normalized.auth == auth_result.auth
    assert normalized.capabilities == auth_result.capabilities
    assert normalized.audiences == auth_result.audiences
    assert normalized.scopes == auth_result.scopes
    assert normalized.verified_audiences == auth_result.audiences
    assert normalized.verified_scopes == auth_result.scopes
  end

  test "canonical and compatibility auth evidence cannot contradict each other" do
    assert {:ok, context} =
             Context.build(unique_name("conflicting-auth-evidence"), state_scope: :request)

    auth =
      Auth.new(fn _input, _context ->
        {:ok,
         %AuthResult{
           audiences: ["https://mcp.example.com/public/mcp"],
           verified_audiences: ["https://other.example.com/mcp"]
         }}
      end)

    assert {:error, %Error{code: :internal_error} = error} = Auth.resolve(auth, context, %{})
    assert error.message =~ "authenticator"
  end

  test "rejects unsafe resource-server metadata" do
    assert {:error, :https_resource_required} =
             ProtectedResource.new(
               resource: "http://mcp.example.com/mcp",
               authorization_servers: ["https://auth.example.com"]
             )

    assert {:error, :invalid_authorization_server} =
             ProtectedResource.new(
               resource: "https://mcp.example.com/mcp",
               authorization_servers: ["http://auth.example.com"]
             )

    assert {:error, :header_bearer_method_required} =
             ProtectedResource.new(
               resource: "https://mcp.example.com/mcp",
               authorization_servers: ["https://auth.example.com"],
               bearer_methods_supported: ["query"]
             )

    assert {:error, {:reserved_extension, "resource"}} =
             ProtectedResource.new(
               resource: "https://mcp.example.com/mcp",
               authorization_servers: ["https://auth.example.com"],
               extensions: %{"resource" => "https://evil.example.com"}
             )

    assert {:error, {:unsupported_required_scopes, ["files:write"]}} =
             ProtectedResource.new(
               resource: "https://mcp.example.com/mcp",
               authorization_servers: ["https://auth.example.com"],
               scopes_supported: ["files:read"],
               required_scopes: ["files:write"]
             )
  end

  test "server options normalize protected-resource configuration" do
    server =
      FastestMCP.server(unique_name("protected-config"),
        protected_resource: [
          resource: "https://MCP.example.com:443/public/mcp",
          authorization_servers: ["https://AUTH.example.com:443/tenant"],
          scopes_supported: ["files:read", "files:write"],
          required_scopes: ["files:read"]
        ]
      )

    assert %ProtectedResource{
             resource: "https://mcp.example.com/public/mcp",
             authorization_servers: ["https://auth.example.com/tenant"],
             scopes_supported: ["files:read", "files:write"],
             required_scopes: ["files:read"]
           } = server.protected_resource
  end

  test "well-known plug serves only the configured GET metadata route" do
    opts =
      WellKnownHTTP.init(
        server_name: "metadata-server",
        allowed_hosts: ["mcp.example.com"],
        path: "/public/mcp",
        protected_resource: protected_resource()
      )

    conn =
      :get
      |> conn("https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp")
      |> WellKnownHTTP.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert JSON.decode!(conn.resp_body)["resource"] == "https://mcp.example.com/public/mcp"

    method_conn =
      :post
      |> conn("https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp")
      |> WellKnownHTTP.call(opts)

    assert method_conn.status == 405
    assert get_resp_header(method_conn, "allow") == ["GET"]

    missing_conn =
      :get
      |> conn("https://mcp.example.com/.well-known/oauth-protected-resource")
      |> WellKnownHTTP.call(opts)

    assert missing_conn.status == 404
  end

  test "well-known child defaults to loopback and guards external listeners" do
    server_name = unique_name("protected-child")

    assert %{start: {Bandit, :start_link, [bandit_options]}} =
             FastestMCP.well_known_http_child_spec(server_name)

    assert Keyword.fetch!(bandit_options, :ip) == :loopback

    assert_raise ArgumentError,
                 "external HTTP listeners require a concrete allowed_hosts list",
                 fn ->
                   FastestMCP.well_known_http_child_spec(server_name,
                     bandit_options: [ip: {0, 0, 0, 0}]
                   )
                 end
  end

  test "the public HTTP app serves metadata from the running server on the MCP origin" do
    server_name = unique_name("protected-public-mount")

    server =
      FastestMCP.server(server_name,
        auth: allow_auth(),
        protected_resource: protected_resource()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["mcp.example.com", "alias.example.com"],
        path: "/public/mcp",
        json_response: true
      )

    conn =
      :get
      |> conn("https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp")
      |> app.()

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == ProtectedResource.metadata(protected_resource())

    wrong_origin =
      :get
      |> conn("https://alias.example.com/.well-known/oauth-protected-resource/public/mcp")
      |> app.()

    assert wrong_origin.status == 404

    wrong_mcp_origin = initialize_request(app, "https://alias.example.com/public/mcp")
    assert wrong_mcp_origin.status == 403

    assert [challenge] = get_resp_header(wrong_mcp_origin, "www-authenticate")
    assert challenge =~ ~s(resource_metadata="https://mcp.example.com/)
  end

  test "a separately mounted well-known plug reads the running server configuration" do
    server_name = unique_name("protected-phoenix-mount")

    server =
      FastestMCP.server(server_name,
        auth: allow_auth(),
        protected_resource: protected_resource()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    opts =
      WellKnownHTTP.init(
        server_name: server_name,
        path: "/public/mcp",
        base_url: "https://mcp.example.com",
        allowed_hosts: ["mcp.example.com"]
      )

    response =
      :get
      |> conn("https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp")
      |> WellKnownHTTP.call(opts)

    assert response.status == 200
    assert JSON.decode!(response.resp_body) == ProtectedResource.metadata(protected_resource())
  end

  test "protected HTTP auth receives the exact resource and required scopes" do
    server_name = unique_name("protected-auth-input")
    test_pid = self()

    authenticator = fn input, context ->
      send(test_pid, {:auth_input, input, context.request_metadata})

      {:ok,
       %{
         "audiences" => [input["expected_resource"]],
         "scopes" => input["expected_scopes"],
         principal: %{"sub" => "user-1"},
         auth: %{provider: :test},
         capabilities: []
       }}
    end

    protected_resource =
      ProtectedResource.new!(
        resource: "https://mcp.example.com/public/mcp",
        authorization_servers: ["https://auth.example.com"],
        scopes_supported: ["files:read", "files:write"],
        required_scopes: ["files:read"]
      )

    server =
      FastestMCP.server(server_name,
        auth: authenticator,
        protected_resource: protected_resource
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      server_name
      |> protected_app()
      |> initialize_request("https://mcp.example.com/public/mcp",
        authorization: "Bearer verified-token"
      )

    assert response.status == 200

    assert_receive {:auth_input,
                    %{
                      "authorization" => "Bearer verified-token",
                      "expected_resource" => "https://mcp.example.com/public/mcp",
                      "expected_scopes" => ["files:read"]
                    },
                    %{
                      expected_resource: "https://mcp.example.com/public/mcp",
                      expected_scopes: ["files:read"]
                    }}
  end

  test "protected HTTP rejects missing or mismatched verified audience evidence" do
    for {suffix, verified_audiences} <- [missing: [], mismatched: ["https://other.example/mcp"]] do
      server_name = unique_name("protected-audience-#{suffix}")

      authenticator = fn input, _context ->
        {:ok,
         %{
           principal: %{"sub" => "user-1"},
           verified_audiences: verified_audiences,
           verified_scopes: input["expected_scopes"]
         }}
      end

      server =
        FastestMCP.server(server_name,
          auth: authenticator,
          protected_resource: protected_resource()
        )

      assert {:ok, _pid} = FastestMCP.start_server(server)

      response =
        server_name
        |> protected_app()
        |> initialize_request("https://mcp.example.com/public/mcp",
          authorization: "Bearer wrong-audience"
        )

      assert response.status == 401
      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ ~s(error="invalid_token")
      assert challenge =~ ~s(resource_metadata="https://mcp.example.com/)
    end
  end

  test "protected HTTP rejects missing verified scope evidence" do
    server_name = unique_name("protected-scope-evidence")

    authenticator = fn input, _context ->
      {:ok,
       %{
         principal: %{"sub" => "user-1"},
         verified_audiences: [input["expected_resource"]],
         verified_scopes: []
       }}
    end

    server =
      FastestMCP.server(server_name,
        auth: authenticator,
        protected_resource: protected_resource()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      server_name
      |> protected_app()
      |> initialize_request("https://mcp.example.com/public/mcp",
        authorization: "Bearer missing-scope"
      )

    assert response.status == 403
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="files:read")
  end

  test "component scope denial returns 403 with exactly the missing scopes" do
    server_name = unique_name("protected-component-scope")

    protected_resource =
      ProtectedResource.new!(
        resource: "https://mcp.example.com/public/mcp",
        authorization_servers: ["https://auth.example.com"],
        scopes_supported: ["files:read", "files:admin"],
        required_scopes: ["files:read"]
      )

    authenticator = fn input, _context ->
      {:ok,
       %{
         principal: {"https://auth.example.com", "user-1"},
         audiences: [input["expected_resource"]],
         scopes: ["files:read"]
       }}
    end

    server =
      FastestMCP.server(server_name,
        auth: authenticator,
        protected_resource: protected_resource
      )
      |> FastestMCP.add_tool("admin", fn -> "secret" end,
        auth: Authorization.require_scopes("files:admin")
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    payload =
      ProtocolTest.modern_request(1, "tools/call", %{"name" => "admin", "arguments" => %{}})

    response =
      :post
      |> conn("https://mcp.example.com/public/mcp", JSON.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer verified-token")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "admin")
      |> then(protected_app(server_name))

    assert response.status == 403
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="files:admin")

    assert get_in(JSON.decode!(response.resp_body), ["error", "data", "fastestmcp", "code"]) ==
             "forbidden"
  end

  test "opaque component denial returns 403 without a scope challenge" do
    server_name = unique_name("protected-component-opaque")

    server =
      FastestMCP.server(server_name,
        auth: allow_auth(),
        protected_resource: protected_resource()
      )
      |> FastestMCP.add_tool("private", fn -> "secret" end, auth: fn _context -> false end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    payload =
      ProtocolTest.modern_request(1, "tools/call", %{"name" => "private", "arguments" => %{}})

    response =
      :post
      |> conn("https://mcp.example.com/public/mcp", JSON.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer verified-token")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "private")
      |> then(protected_app(server_name))

    assert response.status == 403
    assert get_resp_header(response, "www-authenticate") == []
  end

  test "protected HTTP rejects query tokens before invoking the authenticator" do
    server_name = unique_name("protected-query-token")
    test_pid = self()

    authenticator = fn _input, _context ->
      send(test_pid, :authenticator_called)
      {:ok, %{principal: "unexpected"}}
    end

    server =
      FastestMCP.server(server_name,
        auth: authenticator,
        protected_resource: protected_resource()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      server_name
      |> protected_app()
      |> initialize_request(
        "https://mcp.example.com/public/mcp?%61ccess_token=leaked",
        authorization: "Bearer verified-token"
      )

    assert response.status == 400
    assert JSON.decode!(response.resp_body)["error"]["code"] == "bad_request"
    refute_received :authenticator_called

    malformed =
      server_name
      |> protected_app()
      |> initialize_request("https://mcp.example.com/public/mcp?token=%ZZ")

    assert malformed.status == 400
    refute_received :authenticator_called
  end

  test "protected HTTP fails closed when no authenticator is configured" do
    server_name = unique_name("protected-no-auth")

    server =
      FastestMCP.server(server_name,
        protected_resource: protected_resource()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      server_name
      |> protected_app()
      |> initialize_request("https://mcp.example.com/public/mcp")

    assert response.status == 401
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ ~s(resource_metadata="https://mcp.example.com/)
  end

  test "protected-resource challenges include discovery and authoritative scope" do
    server_name = unique_name("protected-challenge")

    server =
      FastestMCP.server(server_name,
        protected_resource: protected_resource()
      )
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "wrong-scope" => %{
            audiences: ["https://mcp.example.com/public/mcp"],
            scopes: []
          }
        },
        required_scopes: ["files:read"]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    app = protected_app(server_name)

    unauthorized = initialize_request(app, "https://mcp.example.com/public/mcp")
    assert unauthorized.status == 401
    assert [unauthorized_challenge] = get_resp_header(unauthorized, "www-authenticate")

    assert unauthorized_challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp")

    assert unauthorized_challenge =~ ~s(scope="files:read")
    assert unauthorized_challenge =~ ~s(error="invalid_token")

    forbidden =
      initialize_request(app, "https://mcp.example.com/public/mcp",
        authorization: "Bearer wrong-scope"
      )

    assert forbidden.status == 403
    assert [forbidden_challenge] = get_resp_header(forbidden, "www-authenticate")
    assert forbidden_challenge =~ ~s(scope="files:read")
    assert forbidden_challenge =~ ~s(error="insufficient_scope")
  end

  defp protected_resource do
    ProtectedResource.new!(
      resource: "https://MCP.example.com:443/public/mcp",
      authorization_servers: ["https://AUTH.example.com:443/tenant"],
      scopes_supported: ["files:read"],
      required_scopes: ["files:read"],
      resource_name: "Example MCP",
      extensions: %{"x-service" => "documents"}
    )
  end

  defp protected_app(server_name) do
    FastestMCP.http_app(server_name,
      allowed_hosts: ["mcp.example.com"],
      path: "/public/mcp",
      json_response: true
    )
  end

  defp initialize_request(app, url, opts \\ []) do
    request = ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())

    conn =
      :post
      |> conn(url, JSON.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> maybe_put_authorization(Keyword.get(opts, :authorization))

    app.(conn)
  end

  defp maybe_put_authorization(conn, nil), do: conn

  defp maybe_put_authorization(conn, authorization) do
    put_req_header(conn, "authorization", authorization)
  end

  defp allow_auth do
    fn input, _context ->
      {:ok,
       %{
         principal: %{"sub" => "allowed"},
         auth: %{provider: :test},
         verified_audiences: [input["expected_resource"]],
         verified_scopes: input["expected_scopes"]
       }}
    end
  end

  defp unique_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
