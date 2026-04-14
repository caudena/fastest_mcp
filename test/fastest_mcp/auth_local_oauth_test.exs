defmodule FastestMCP.AuthLocalOAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.JWTIssuer
  alias FastestMCP.Auth.PrivateKeyJWT

  defmodule FakeUpstreamStrategy do
    def authorize_url(config) do
      authorization_params = config[:authorization_params] |> Enum.into(%{})
      state = "upstream-state-123"

      {:ok,
       %{
         url:
           "https://github.com/login/oauth/authorize?" <>
             URI.encode_query(%{
               "client_id" => config[:client_id],
               "redirect_uri" => config[:redirect_uri],
               "scope" => authorization_params["scope"] || authorization_params[:scope] || "",
               "state" => state
             }),
         session_params: %{"state" => state}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{"access_token" => "gho_mock_token_" <> params["code"]},
         "user" => %{"sub" => "github-user-123", "login" => "octocat"},
         "redirect_uri" => config[:redirect_uri]
       }}
    end
  end

  defp local_oauth_server(server_name, auth_opts \\ []) do
    auth_opts =
      Keyword.merge(
        [
          required_scopes: ["tools:call"],
          supported_scopes: ["tools:call", "resources:read"]
        ],
        auth_opts
      )

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth, auth_opts)
    |> FastestMCP.add_tool("whoami", fn _args, ctx ->
      %{principal: ctx.principal, capabilities: ctx.capabilities, auth: ctx.auth}
    end)
  end

  defp local_oauth_proxy_server(server_name, auth_opts \\ []) do
    auth_opts =
      Keyword.merge(
        [
          consent: true,
          required_scopes: ["tools:call"],
          supported_scopes: ["tools:call", "resources:read"],
          upstream_oauth_flow:
            AssentFlow.new(FakeUpstreamStrategy,
              client_id: "github-client-id",
              client_secret: "github-client-secret"
            )
        ],
        auth_opts
      )

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth, auth_opts)
    |> FastestMCP.add_tool("whoami", fn _args, ctx ->
      %{principal: ctx.principal, capabilities: ctx.capabilities, auth: ctx.auth}
    end)
  end

  test "local oauth exposes discovery metadata and dynamic client registration" do
    server_name = "local-oauth-metadata-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 service_documentation_url: "https://docs.example.com/"
               )
             )

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert metadata_conn.status == 200

    assert %{
             "issuer" => "https://mcp.example.com",
             "authorization_endpoint" => "https://mcp.example.com/authorize",
             "token_endpoint" => "https://mcp.example.com/token",
             "registration_endpoint" => "https://mcp.example.com/register",
             "revocation_endpoint" => "https://mcp.example.com/revoke",
             "client_id_metadata_document_supported" => true,
             "service_documentation" => "https://docs.example.com",
             "token_endpoint_auth_signing_alg_values_supported" => signing_algorithms
           } = Jason.decode!(metadata_conn.resp_body)

    assert Enum.sort(signing_algorithms) ==
             Enum.sort(FastestMCP.Auth.PrivateKeyJWT.supported_algorithms())

    assert MapSet.new(
             Jason.decode!(metadata_conn.resp_body)["token_endpoint_auth_methods_supported"]
           ) ==
             MapSet.new(["none", "client_secret_post", "client_secret_basic", "private_key_jwt"])

    protected_resource_conn =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert protected_resource_conn.status == 200

    assert %{
             "resource" => "https://mcp.example.com/mcp",
             "authorization_servers" => ["https://mcp.example.com"],
             "scopes_supported" => ["tools:call", "resources:read"]
           } = Jason.decode!(protected_resource_conn.resp_body)

    register_conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: "Test Client",
          redirect_uris: ["http://localhost:4001/callback"],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "client_secret_post",
          scope: "tools:call"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert register_conn.status == 201

    assert %{
             "client_id" => client_id,
             "client_secret" => client_secret,
             "redirect_uris" => ["http://localhost:4001/callback"],
             "grant_types" => ["authorization_code", "refresh_token"],
             "response_types" => ["code"],
             "token_endpoint_auth_method" => "client_secret_post",
             "scope" => "tools:call"
           } = Jason.decode!(register_conn.resp_body)

    assert is_binary(client_id) and client_id != ""
    assert is_binary(client_secret) and client_secret != ""
  end

  test "local oauth uses path-aware discovery when base_url includes a mount path" do
    server_name =
      "local-oauth-path-aware-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server/api")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://api.example.com/api"
      )

    assert metadata_conn.status == 200

    assert %{
             "issuer" => "https://api.example.com/api",
             "authorization_endpoint" => "https://api.example.com/api/authorize",
             "token_endpoint" => "https://api.example.com/api/token",
             "registration_endpoint" => "https://api.example.com/api/register",
             "revocation_endpoint" => "https://api.example.com/api/revoke"
           } = Jason.decode!(metadata_conn.resp_body)

    root_metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://api.example.com/api"
      )

    assert root_metadata_conn.status == 404

    protected_resource_conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://api.example.com/api"
      )

    assert protected_resource_conn.status == 200

    assert %{
             "resource" => "https://api.example.com/api/mcp",
             "authorization_servers" => ["https://api.example.com/api"]
           } = Jason.decode!(protected_resource_conn.resp_body)
  end

  test "local oauth can publish discovery at issuer_url while keeping operational endpoints at base_url" do
    server_name =
      "local-oauth-issuer-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 issuer_url: "https://api.example.com",
                 service_documentation_url: "https://docs.example.com/"
               )
             )

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://api.example.com/api"
      )

    assert metadata_conn.status == 200

    assert %{
             "issuer" => "https://api.example.com/api",
             "authorization_endpoint" => "https://api.example.com/api/authorize",
             "token_endpoint" => "https://api.example.com/api/token",
             "service_documentation" => "https://docs.example.com"
           } = Jason.decode!(metadata_conn.resp_body)

    protected_resource_conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://api.example.com/api"
      )

    assert protected_resource_conn.status == 200

    assert %{
             "authorization_servers" => ["https://api.example.com"]
           } = Jason.decode!(protected_resource_conn.resp_body)
  end

  test "authorization code exchange yields tokens that authorize MCP calls" do
    server_name = "local-oauth-code-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    client = register_client(server_name)
    code_verifier = "code-verifier-123"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "state-123",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert authorize_conn.status == 302
    [location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(location)

    assert %{"code" => code, "state" => "state-123"} = URI.decode_query(query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200
    assert get_resp_header(token_conn, "cache-control") == ["no-store"]
    assert get_resp_header(token_conn, "pragma") == ["no-cache"]

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "scope" => "tools:call"
           } = Jason.decode!(token_conn.resp_body)

    assert is_binary(access_token) and access_token != ""
    assert is_binary(refresh_token) and refresh_token != ""

    mcp_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert mcp_conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{"client_id" => client_id},
               "capabilities" => ["tools:call"],
               "auth" => %{
                 "client_id" => client_id,
                 "provider" => "local_oauth",
                 "scopes" => ["tools:call"],
                 "token_type" => "Bearer"
               }
             }
           } = Jason.decode!(mcp_conn.resp_body)

    assert client_id == client["client_id"]
  end

  test "authorization code exchange supports client_secret_basic" do
    server_name = "local-oauth-basic-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    client =
      register_client(server_name, %{
        token_endpoint_auth_method: "client_secret_basic"
      })

    code_verifier = "code-verifier-basic-123"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "state-basic",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert authorize_conn.status == 302
    [location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(location)
    assert %{"code" => code, "state" => "state-basic"} = URI.decode_query(query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("authorization", basic_auth(client["client_id"], client["client_secret"]))
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200

    assert %{"access_token" => _access_token, "token_type" => "Bearer"} =
             Jason.decode!(token_conn.resp_body)
  end

  test "refresh token rotation invalidates the old token pair" do
    server_name = "local-oauth-refresh-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    client = register_client(server_name)

    %{"access_token" => access_token, "refresh_token" => refresh_token} =
      authorize_and_exchange(server_name, client)

    refresh_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "refresh_token" => refresh_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert refresh_conn.status == 200
    assert get_resp_header(refresh_conn, "cache-control") == ["no-store"]
    assert get_resp_header(refresh_conn, "pragma") == ["no-cache"]

    assert %{
             "access_token" => rotated_access_token,
             "refresh_token" => rotated_refresh_token
           } = Jason.decode!(refresh_conn.resp_body)

    refute rotated_access_token == access_token
    refute rotated_refresh_token == refresh_token

    stale_refresh_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "refresh_token" => refresh_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert stale_refresh_conn.status == 400
    assert get_resp_header(stale_refresh_conn, "cache-control") == ["no-store"]
    assert get_resp_header(stale_refresh_conn, "pragma") == ["no-cache"]
    assert %{"error" => "invalid_grant"} = Jason.decode!(stale_refresh_conn.resp_body)

    stale_access_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert stale_access_conn.status == 401

    assert %{
             "error" => "invalid_token",
             "error_description" => description
           } = Jason.decode!(stale_access_conn.resp_body)

    assert description =~ "clear authentication tokens"
    assert description =~ "automatically re-register"
    [challenge] = get_resp_header(stale_access_conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ "resource_metadata="
  end

  test "revocation invalidates issued access tokens" do
    server_name = "local-oauth-revoke-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    client = register_client(server_name)
    %{"access_token" => access_token} = authorize_and_exchange(server_name, client)

    revoke_conn =
      conn(
        :post,
        "/revoke",
        URI.encode_query(%{
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "token" => access_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert revoke_conn.status == 200
    assert get_resp_header(revoke_conn, "cache-control") == ["no-store"]
    assert get_resp_header(revoke_conn, "pragma") == ["no-cache"]
    assert Jason.decode!(revoke_conn.resp_body) == %{}

    revoked_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert revoked_conn.status == 401

    assert %{
             "error" => "invalid_token",
             "error_description" => description
           } = Jason.decode!(revoked_conn.resp_body)

    assert description =~ "clear authentication tokens"
    assert description =~ "automatically re-register"
  end

  test "local oauth can issue JWT access and refresh tokens when configured" do
    server_name = "local-oauth-jwt-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name, jwt_signing_key: "test-secret")
             )

    client = register_client(server_name)

    %{"access_token" => access_token, "refresh_token" => refresh_token} =
      authorize_and_exchange(server_name, client)

    assert length(String.split(access_token, ".")) == 3
    assert length(String.split(refresh_token, ".")) == 3

    signing_key =
      JWTIssuer.derive_jwt_key(
        low_entropy_material: "test-secret",
        salt: "fastestmcp-jwt-signing-key"
      )

    issuer =
      JWTIssuer.new(
        issuer: "http://www.example.com",
        audience: "http://www.example.com/mcp",
        signing_key: signing_key
      )

    assert %{
             "client_id" => client_id,
             "scope" => "tools:call",
             "token_use" => "refresh"
           } = JWTIssuer.verify_token(issuer, refresh_token, expected_token_use: "refresh")

    assert client_id == client["client_id"]

    assert %{"client_id" => ^client_id, "scope" => "tools:call"} =
             JWTIssuer.verify_token(issuer, access_token)

    mcp_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert mcp_conn.status == 200
  end

  test "token endpoint returns invalid_client for malformed basic auth" do
    server_name =
      "local-oauth-basic-invalid-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code"
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("authorization", "Basic !!!not-base64!!!")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 401
    assert %{"error" => "invalid_client"} = Jason.decode!(conn.resp_body)
  end

  test "consent flow issues authorization code only after csrf-protected approval" do
    server_name = "local-oauth-consent-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth,
        consent: true,
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call", "resources:read"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> %{principal: ctx.principal} end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name)
    code_verifier = "consent-verifier-123"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "consent-state",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert authorize_conn.status == 302
    [consent_location] = get_resp_header(authorize_conn, "location")
    assert consent_location =~ "/consent?txn_id="
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_page_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert consent_page_conn.status == 200
    assert get_resp_header(consent_page_conn, "x-frame-options") == ["DENY"]
    assert consent_page_conn.resp_body =~ "Authorize"
    assert consent_page_conn.resp_body =~ txn_id

    [cookie_header | _] = get_resp_header(consent_page_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    [_, csrf_token] =
      Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_page_conn.resp_body)

    approved_conn =
      conn(
        :post,
        "/consent",
        URI.encode_query(%{
          "action" => "approve",
          "txn_id" => txn_id,
          "csrf_token" => csrf_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert approved_conn.status == 302
    [callback_location] = get_resp_header(approved_conn, "location")
    %URI{query: callback_query} = URI.parse(callback_location)
    assert %{"code" => code, "state" => "consent-state"} = URI.decode_query(callback_query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200
    assert %{"access_token" => _access_token} = Jason.decode!(token_conn.resp_body)
  end

  test "consent approval is rejected without the csrf cookie" do
    server_name =
      "local-oauth-consent-csrf-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth,
        consent: true,
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> %{principal: ctx.principal} end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name)

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "csrf-state"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_page_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [_, csrf_token] =
      Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_page_conn.resp_body)

    rejected_conn =
      conn(
        :post,
        "/consent",
        URI.encode_query(%{
          "action" => "approve",
          "txn_id" => txn_id,
          "csrf_token" => csrf_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert rejected_conn.status == 403
    assert %{"error" => "invalid_request"} = Jason.decode!(rejected_conn.resp_body)
  end

  test "authorize returns html guidance for unregistered browser clients" do
    server_name = "local-oauth-html-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name,
        metadata: %{
          display_name: "My Custom Server",
          icons: [%{src: "https://example.com/icon.png"}]
        }
      )
      |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth,
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call", "resources:read"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, capabilities: ctx.capabilities, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => "missing-client",
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "browser-state"
          })
      )
      |> put_req_header("accept", "text/html,application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert conn.status == 400
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert conn.resp_body =~ "Client Not Registered"
    assert conn.resp_body =~ "missing-client"
    assert conn.resp_body =~ "My Custom Server"
    assert conn.resp_body =~ "https://example.com/icon.png"
    assert conn.resp_body =~ ".well-known/oauth-authorization-server"
    assert conn.resp_body =~ "/register"

    assert get_resp_header(conn, "link") |> List.first() =~
             "http://oauth.net/core/2.1/#registration"
  end

  test "authorize returns enhanced json guidance for unregistered api clients" do
    server_name = "local-oauth-json-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => "missing-client",
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "json-state"
          })
      )
      |> put_req_header("accept", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert conn.status == 400
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert get_resp_header(conn, "link") |> List.first() =~
             "http://oauth.net/core/2.1/#registration"

    assert %{
             "error" => "invalid_request",
             "state" => "json-state",
             "registration_endpoint" => "https://mcp.example.com/register",
             "authorization_server_metadata" =>
               "https://mcp.example.com/.well-known/oauth-authorization-server",
             "error_description" => description
           } = Jason.decode!(conn.resp_body)

    assert description =~ "missing-client"
    assert description =~ "re-register"
  end

  test "oauth-protected MCP calls return insufficient_scope for tokens without required scopes" do
    server_name =
      "local-oauth-insufficient-scope-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 required_scopes: ["tools:call"],
                 supported_scopes: ["tools:call", "resources:read"]
               )
             )

    client = register_client(server_name, %{scope: "resources:read"})
    code_verifier = "scope-verifier-123"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "scope-state",
            "scope" => "resources:read",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert authorize_conn.status == 302
    [location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(location)
    %{"code" => code} = URI.decode_query(query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200
    %{"access_token" => access_token} = Jason.decode!(token_conn.resp_body)

    forbidden_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert forbidden_conn.status == 403

    assert %{
             "error" => "insufficient_scope",
             "error_description" => description
           } = Jason.decode!(forbidden_conn.resp_body)

    assert description =~ "scope"

    [challenge] = get_resp_header(forbidden_conn, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ "resource_metadata="
  end

  test "redirect uri allowlist patterns support dynamic callback ports" do
    server_name = "local-oauth-patterns-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: "Pattern Client",
          redirect_uris: ["http://localhost:3000/callback"],
          allowed_redirect_uri_patterns: ["http://localhost:*/callback"],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "client_secret_post",
          scope: "tools:call"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 201
    client = Jason.decode!(conn.resp_body)
    assert client["allowed_redirect_uri_patterns"] == ["http://localhost:*/callback"]

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:43210/callback",
            "state" => "pattern-state"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert authorize_conn.status == 302

    bypass_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost@evil.com/callback",
            "state" => "pattern-state"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert bypass_conn.status == 400
    assert %{"error" => "invalid_request"} = Jason.decode!(bypass_conn.resp_body)
  end

  test "cimd clients allow wildcard localhost callback ports" do
    server_name =
      "local-oauth-cimd-wildcard-" <> Integer.to_string(System.unique_integer([:positive]))

    client_id = "https://example.com/clients/wildcard.json"

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 cimd_fetcher: fn ^client_id ->
                   {:ok,
                    %{
                      "client_id" => client_id,
                      "client_name" => "Wildcard CIMD Client",
                      "redirect_uris" => ["http://localhost:*/callback"],
                      "token_endpoint_auth_method" => "none",
                      "scope" => "tools:call"
                    }}
                 end
               )
             )

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id,
            "redirect_uri" => "http://localhost:54321/callback",
            "state" => "cimd-state"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    %URI{host: host, port: port, path: path, query: query} = URI.parse(location)
    assert host == "localhost"
    assert port == 54321
    assert path == "/callback"
    assert %{"code" => _code, "state" => "cimd-state"} = URI.decode_query(query)
  end

  test "cimd clients may omit redirect_uri only for a single exact uri" do
    server_name =
      "local-oauth-cimd-default-" <> Integer.to_string(System.unique_integer([:positive]))

    client_id = "https://example.com/clients/default.json"

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 cimd_fetcher: fn ^client_id ->
                   {:ok,
                    %{
                      "client_id" => client_id,
                      "redirect_uris" => ["http://localhost:4001/callback"],
                      "token_endpoint_auth_method" => "none"
                    }}
                 end
               )
             )

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id,
            "state" => "cimd-default"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    %URI{host: host, port: port, path: path, query: query} = URI.parse(location)
    assert host == "localhost"
    assert port == 4001
    assert path == "/callback"
    assert %{"code" => _code, "state" => "cimd-default"} = URI.decode_query(query)
  end

  test "cimd clients require redirect_uri when metadata only provides wildcard redirects" do
    server_name =
      "local-oauth-cimd-missing-redirect-" <>
        Integer.to_string(System.unique_integer([:positive]))

    client_id = "https://example.com/clients/needs-redirect.json"

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 cimd_fetcher: fn ^client_id ->
                   {:ok,
                    %{
                      "client_id" => client_id,
                      "redirect_uris" => ["http://localhost:*/callback"],
                      "token_endpoint_auth_method" => "none"
                    }}
                 end
               )
             )

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 400

    assert %{
             "error" => "invalid_request",
             "error_description" => description
           } = Jason.decode!(conn.resp_body)

    assert description =~ "redirect_uri must be specified"
  end

  test "cimd clients respect server redirect allowlists" do
    server_name =
      "local-oauth-cimd-allowlist-" <> Integer.to_string(System.unique_integer([:positive]))

    client_id = "https://example.com/clients/allowlist.json"

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 allowed_client_redirect_uris: ["http://localhost:*"],
                 cimd_fetcher: fn ^client_id ->
                   {:ok,
                    %{
                      "client_id" => client_id,
                      "redirect_uris" => ["https://evil.com/callback"],
                      "token_endpoint_auth_method" => "none"
                    }}
                 end
               )
             )

    conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id,
            "redirect_uri" => "https://evil.com/callback"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 400
    assert %{"error" => "invalid_request"} = Jason.decode!(conn.resp_body)
  end

  test "cimd private_key_jwt clients exchange authorization codes with signed assertions" do
    server_name =
      "local-oauth-cimd-private-key-" <> Integer.to_string(System.unique_integer([:positive]))

    client_id = "https://example.com/clients/private-key.json"
    {private_jwk, public_jwks} = rsa_key_pair()

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 cimd_fetcher: fn ^client_id ->
                   {:ok,
                    %{
                      "client_id" => client_id,
                      "redirect_uris" => ["http://localhost:4001/callback"],
                      "token_endpoint_auth_method" => "private_key_jwt",
                      "jwks" => public_jwks
                    }}
                 end
               )
             )

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client_id,
            "redirect_uri" => "http://localhost:4001/callback"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert authorize_conn.status == 302
    [location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(location)
    %{"code" => code} = URI.decode_query(query)

    client_assertion =
      client_assertion(private_jwk, client_id, "https://mcp.example.com/token",
        jti: "local-oauth-private-key-jwt"
      )

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "client_assertion_type" => PrivateKeyJWT.assertion_type(),
          "client_assertion" => client_assertion
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert token_conn.status == 200

    assert %{"access_token" => _access_token, "token_type" => "Bearer"} =
             Jason.decode!(token_conn.resp_body)
  end

  test "oauth proxy allows dynamic redirect uris by default and can be restricted" do
    server_name =
      "local-oauth-proxy-redirects-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_proxy_server(server_name))

    client = register_client(server_name)

    permissive_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:54321/callback",
            "state" => "proxy-permissive"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert permissive_conn.status == 302
    [permissive_location] = get_resp_header(permissive_conn, "location")
    assert permissive_location =~ "/consent?txn_id="

    restricted_server_name =
      "local-oauth-proxy-restricted-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_proxy_server(restricted_server_name,
                 allowed_client_redirect_uris: ["http://localhost:*"]
               )
             )

    restricted_client = register_client(restricted_server_name)

    restricted_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => restricted_client["client_id"],
            "redirect_uri" => "https://evil.com/callback",
            "state" => "proxy-restricted"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: restricted_server_name,
        base_url: "https://mcp.example.com"
      )

    assert restricted_conn.status == 400
    assert %{"error" => "invalid_request"} = Jason.decode!(restricted_conn.resp_body)
  end

  test "oauth proxy approval redirects upstream with proxy callback uri" do
    server_name = "local-oauth-proxy-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_proxy_server(server_name))

    client = register_client(server_name)

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "proxy-state",
            "scope" => "tools:call",
            "code_challenge" => "challenge",
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_page_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [cookie_header | _] = get_resp_header(consent_page_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    [_, csrf_token] =
      Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_page_conn.resp_body)

    approve_conn =
      conn(
        :post,
        "/consent",
        URI.encode_query(%{
          "action" => "approve",
          "txn_id" => txn_id,
          "csrf_token" => csrf_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302
    [upstream_location] = get_resp_header(approve_conn, "location")
    upstream_uri = URI.parse(upstream_location)
    upstream_query = URI.decode_query(upstream_uri.query || "")

    assert upstream_uri.host == "github.com"
    assert upstream_uri.path == "/login/oauth/authorize"
    assert upstream_query["client_id"] == "github-client-id"
    assert upstream_query["redirect_uri"] == "https://mcp.example.com/auth/callback"
    assert upstream_query["state"] == "upstream-state-123"
  end

  test "oauth proxy callback issues local code and access token for protected MCP calls" do
    server_name =
      "local-oauth-proxy-callback-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_proxy_server(server_name))

    client = register_client(server_name)
    code_verifier = "proxy-code-verifier"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "proxy-state",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_page_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [cookie_header | _] = get_resp_header(consent_page_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    [_, csrf_token] =
      Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_page_conn.resp_body)

    _approve_conn =
      conn(
        :post,
        "/consent",
        URI.encode_query(%{
          "action" => "approve",
          "txn_id" => txn_id,
          "csrf_token" => csrf_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    callback_conn =
      conn(:get, "/auth/callback?code=upstream-code-123&state=upstream-state-123")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert callback_conn.status == 302
    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: client_callback_query} = URI.parse(client_callback_location)

    assert %{"code" => local_code, "state" => "proxy-state"} =
             URI.decode_query(client_callback_query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => local_code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200

    assert %{
             "access_token" => access_token,
             "refresh_token" => _refresh_token
           } = Jason.decode!(token_conn.resp_body)

    protected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert protected_conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{"login" => "octocat", "sub" => "github-user-123"},
               "auth" => %{
                 "provider" => "oauth_proxy",
                 "upstream_access_token" => "gho_mock_token_upstream-code-123"
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  defp register_client(server_name, overrides \\ %{}) do
    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(
          Map.merge(
            %{
              client_name: "Flow Test Client",
              redirect_uris: ["http://localhost:4001/callback"],
              grant_types: ["authorization_code", "refresh_token"],
              response_types: ["code"],
              token_endpoint_auth_method: "client_secret_post",
              scope: "tools:call"
            },
            overrides
          )
        )
      )
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 201
    Jason.decode!(conn.resp_body)
  end

  defp authorize_and_exchange(server_name, client) do
    code_verifier = "refresh-flow-verifier"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => "refresh-state",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    [location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(location)
    %{"code" => code} = URI.decode_query(query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => code,
          "redirect_uri" => "http://localhost:4001/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200
    Jason.decode!(token_conn.resp_body)
  end

  defp s256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
  end

  defp basic_auth(client_id, client_secret) do
    "Basic " <> Base.encode64("#{client_id}:#{client_secret}")
  end

  defp rsa_key_pair do
    private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    public_jwk = JOSE.JWK.to_public(private_jwk)
    {_fields, jwk_map} = JOSE.JWK.to_map(public_jwk)
    {private_jwk, %{"keys" => [jwk_map]}}
  end

  defp client_assertion(private_jwk, client_id, token_endpoint, opts) do
    now = System.os_time(:second)

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => token_endpoint,
      "exp" => now + Keyword.get(opts, :expires_in_seconds, 60),
      "iat" => now,
      "jti" => Keyword.fetch!(opts, :jti)
    }

    headers = %{"alg" => "RS256", "kid" => Keyword.get(opts, :kid, "test-key-1")}

    JOSE.JWT.sign(private_jwk, headers, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
