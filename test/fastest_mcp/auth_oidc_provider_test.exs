defmodule FastestMCP.AuthOIDCProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth.OIDC

  @oidc_configuration %{
    "issuer" => "https://accounts.example.com",
    "authorization_endpoint" => "https://accounts.example.com/authorize",
    "token_endpoint" => "https://accounts.example.com/oauth/token",
    "jwks_uri" => "https://accounts.example.com/.well-known/jwks.json",
    "response_types_supported" => ["code"],
    "subject_types_supported" => ["public"],
    "id_token_signing_alg_values_supported" => ["RS256"]
  }

  defmodule FakeOIDCStrategy do
    def authorize_url(config) do
      params = config[:authorization_params] |> Enum.into(%{})
      state = "oidc-state-123"

      {:ok,
       %{
         url:
           "#{config[:base_url]}/authorize?" <>
             URI.encode_query(%{
               "client_id" => config[:client_id],
               "redirect_uri" => config[:redirect_uri],
               "scope" => params["scope"] || params[:scope] || "",
               "audience" => params["audience"] || params[:audience] || "",
               "state" => state
             }),
         session_params: %{"state" => state}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{
           "access_token" => "oidc_access_" <> params["code"],
           "refresh_token" => "oidc_refresh_" <> params["code"],
           "id_token" => "oidc_id_" <> params["code"]
         },
         "user" => %{
           "sub" => "oidc-user-123",
           "email" => "user@example.com"
         },
         "redirect_uri" => config[:redirect_uri]
       }}
    end
  end

  test "oidc token verifier uses client_id audience and drops required scopes when verify_id_token is enabled" do
    opts = %{
      config_url: "https://accounts.example.com/.well-known/openid-configuration",
      openid_configuration: @oidc_configuration,
      client_id: "oidc-client-id",
      client_secret: "oidc-client-secret",
      audience: "https://api.example.com",
      required_scopes: ["read", "write"],
      verify_id_token: true
    }

    assert %{
             jwks_uri: "https://accounts.example.com/.well-known/jwks.json",
             issuer: "https://accounts.example.com",
             audience: "oidc-client-id",
             required_scopes: []
           } = OIDC.token_verifier_options(opts)

    assert OIDC.uses_alternate_verification?(opts)
    assert OIDC.verification_token(%{"access_token" => "a", "id_token" => "b"}, opts) == "b"
  end

  test "oidc verification token defaults to access token and returns nil when verify_id_token is enabled without one" do
    default_opts = %{
      config_url: "https://accounts.example.com/.well-known/openid-configuration",
      openid_configuration: @oidc_configuration,
      client_id: "oidc-client-id",
      client_secret: "oidc-client-secret"
    }

    verify_id_token_opts = Map.put(default_opts, :verify_id_token, true)

    assert OIDC.verification_token(%{"access_token" => "opaque-token"}, default_opts) ==
             "opaque-token"

    assert OIDC.verification_token(%{"access_token" => "opaque-token"}, verify_id_token_opts) ==
             nil
  end

  test "oidc configuration is strict by default and validates required metadata urls" do
    assert_raise ArgumentError, ~r/missing required oidc configuration metadata/, fn ->
      OIDC.fetch_configuration(%{
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: %{
          "issuer" => "https://accounts.example.com",
          "authorization_endpoint" => "https://accounts.example.com/authorize"
        }
      })
    end

    assert_raise ArgumentError, ~r/invalid oidc configuration metadata url: issuer/, fn ->
      OIDC.fetch_configuration(%{
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: Map.put(@oidc_configuration, "issuer", "not-a-url")
      })
    end
  end

  test "oidc configuration can run in non-strict mode" do
    assert %{"strict" => false} =
             OIDC.fetch_configuration(%{
               config_url: "https://accounts.example.com/.well-known/openid-configuration",
               openid_configuration: %{"strict" => false}
             })

    assert %{"issuer" => "not-a-url", "strict" => false} =
             OIDC.fetch_configuration(%{
               config_url: "https://accounts.example.com/.well-known/openid-configuration",
               openid_configuration: %{"issuer" => "not-a-url", "strict" => false}
             })
  end

  test "oidc raises clear errors for missing required options and invalid custom verifier config" do
    assert_raise ArgumentError, ~r/oidc auth requires :config_url/, fn ->
      OIDC.fetch_configuration(%{})
    end

    http_context = %{base_url: "https://mcp.example.com", mcp_base_path: "/mcp"}

    assert_raise ArgumentError, ~r/oidc auth requires :client_id/, fn ->
      OIDC.protected_resource_metadata(http_context, %{
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: @oidc_configuration,
        client_secret: "oidc-client-secret"
      })
    end

    assert_raise ArgumentError, ~r/oidc auth requires :client_secret/, fn ->
      OIDC.protected_resource_metadata(http_context, %{
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: @oidc_configuration,
        client_id: "oidc-client-id"
      })
    end

    assert_raise ArgumentError,
                 ~r/cannot specify :algorithm when providing :token_verifier/,
                 fn ->
                   OIDC.protected_resource_metadata(http_context, %{
                     config_url: "https://accounts.example.com/.well-known/openid-configuration",
                     openid_configuration: @oidc_configuration,
                     client_id: "oidc-client-id",
                     client_secret: "oidc-client-secret",
                     token_verifier: {FastestMCP.Auth.Debug, validate: &(&1 == "ok")},
                     algorithm: "RS256"
                   })
                 end
  end

  test "oidc provider preserves upstream id token metadata across local refresh" do
    server_name = "oidc-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.OIDC,
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: @oidc_configuration,
        client_id: "oidc-client-id",
        client_secret: "oidc-client-secret",
        strategy: FakeOIDCStrategy,
        token_verifier: {FastestMCP.Auth.Debug, validate: &(&1 == "oidc_id_code-123")},
        verify_id_token: true,
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name)
    code_verifier = "oidc-code-verifier"

    approve_conn =
      authorize_and_approve(server_name, client, "oidc-proxy-state", s256(code_verifier),
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302
    [upstream_location] = get_resp_header(approve_conn, "location")
    upstream_query = upstream_location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert upstream_query["audience"] == ""
    assert upstream_query["scope"] == "openid"
    assert upstream_query["state"] == "oidc-state-123"

    callback_conn =
      conn(:get, "/auth/callback?code=code-123&state=oidc-state-123")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert callback_conn.status == 302
    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: callback_query} = URI.parse(client_callback_location)

    assert %{"code" => local_code, "state" => "oidc-proxy-state"} =
             URI.decode_query(callback_query)

    token_conn =
      exchange_code(server_name, client, local_code, code_verifier)

    assert token_conn.status == 200

    %{"access_token" => access_token, "refresh_token" => refresh_token} =
      Jason.decode!(token_conn.resp_body)

    assert_whoami_auth(server_name, access_token, "oidc_id_code-123")

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
    %{"access_token" => rotated_access_token} = Jason.decode!(refresh_conn.resp_body)
    refute rotated_access_token == access_token

    assert_whoami_auth(server_name, rotated_access_token, "oidc_id_code-123")
  end

  test "oidc provider validates upstream access token by default" do
    server_name = "oidc-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.OIDC,
        config_url: "https://accounts.example.com/.well-known/openid-configuration",
        openid_configuration: @oidc_configuration,
        client_id: "oidc-client-id",
        client_secret: "oidc-client-secret",
        strategy: FakeOIDCStrategy,
        token_verifier: {FastestMCP.Auth.Debug, validate: &(&1 == "oidc_access_code-456")},
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name)
    code_verifier = "oidc-access-code-verifier"

    approve_conn =
      authorize_and_approve(server_name, client, "oidc-access-state", s256(code_verifier),
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302

    callback_conn =
      conn(:get, "/auth/callback?code=code-456&state=oidc-state-123")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert callback_conn.status == 302
    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: callback_query} = URI.parse(client_callback_location)

    assert %{"code" => local_code, "state" => "oidc-access-state"} =
             URI.decode_query(callback_query)

    token_conn =
      exchange_code(server_name, client, local_code, code_verifier)

    assert token_conn.status == 200

    %{"access_token" => access_token} = Jason.decode!(token_conn.resp_body)

    assert_whoami_auth(
      server_name,
      access_token,
      "oidc_id_code-456",
      "oidc_access_code-456",
      "oidc_refresh_code-456"
    )
  end

  defp assert_whoami_auth(
         server_name,
         access_token,
         expected_id_token,
         expected_access_token \\ "oidc_access_code-123",
         expected_refresh_token \\ "oidc_refresh_code-123"
       ) do
    protected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert protected_conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{
                 "email" => "user@example.com",
                 "sub" => "oidc-user-123"
               },
               "auth" => %{
                 "provider" => "oauth_proxy",
                 "upstream_access_token" => ^expected_access_token,
                 "upstream_refresh_token" => ^expected_refresh_token,
                 "upstream_id_token" => ^expected_id_token
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  defp authorize_and_approve(server_name, client, state, code_challenge, opts) do
    base_url = Keyword.fetch!(opts, :base_url)

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => state,
            "scope" => "tools:call",
            "code_challenge" => code_challenge,
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name, base_url: base_url)

    assert authorize_conn.status == 302
    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name, base_url: base_url)

    assert consent_conn.status == 200
    [cookie_header | _] = get_resp_header(consent_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()
    [_, csrf_token] = Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_conn.resp_body)

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
    |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name, base_url: base_url)
  end

  defp exchange_code(server_name, client, local_code, code_verifier) do
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
  end

  defp register_client(server_name) do
    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: "OIDC Test Client",
          redirect_uris: ["http://localhost:4001/callback"],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "client_secret_post",
          scope: "tools:call"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 201
    Jason.decode!(conn.resp_body)
  end

  defp s256(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end
end
