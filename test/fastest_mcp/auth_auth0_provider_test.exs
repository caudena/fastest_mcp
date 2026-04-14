defmodule FastestMCP.AuthAuth0ProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth.Auth0

  defmodule FakeAuth0Strategy do
    def authorize_url(config) do
      params = config[:authorization_params] |> Enum.into(%{})
      state = "auth0-state-123"

      {:ok,
       %{
         url:
           "#{config[:base_url]}/authorize?" <>
             URI.encode_query(%{
               "client_id" => config[:client_id],
               "redirect_uri" => config[:redirect_uri],
               "scope" => params["scope"] || params[:scope] || "",
               "audience" => params["audience"] || params[:audience] || "",
               "organization" => params["organization"] || params[:organization] || "",
               "config_path" =>
                 config[:openid_configuration_uri] || config["openid_configuration_uri"] || "",
               "state" => state
             }),
         session_params: %{"state" => state}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{"access_token" => "auth0_access_" <> params["code"]},
         "user" => %{
           "sub" => "auth0|user-123",
           "email" => "user@example.com",
           "name" => "Auth0 User"
         },
         "redirect_uri" => config[:redirect_uri]
       }}
    end
  end

  test "auth0 provider maps config_url to OIDC config and forwards audience" do
    server_name = "auth0-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Auth0,
        config_url: "https://tenant.us.auth0.com/.well-known/openid-configuration",
        client_id: "auth0-client-id",
        client_secret: "auth0-client-secret",
        audience: "https://api.example.com",
        strategy: FakeAuth0Strategy,
        auth0_scopes: ["openid", "email", "profile"],
        extra_authorize_params: %{organization: "org_123"},
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name, "Auth0 Test Client")
    code_verifier = "auth0-code-verifier"

    approve_conn =
      authorize_and_approve(server_name, client, "auth0-proxy-state", s256(code_verifier),
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302
    [upstream_location] = get_resp_header(approve_conn, "location")
    upstream_uri = URI.parse(upstream_location)
    upstream_query = URI.decode_query(upstream_uri.query || "")

    assert upstream_uri.host == "tenant.us.auth0.com"
    assert upstream_uri.path == "/authorize"
    assert upstream_query["client_id"] == "auth0-client-id"
    assert upstream_query["redirect_uri"] == "https://mcp.example.com/auth/callback"
    assert upstream_query["audience"] == "https://api.example.com"
    assert upstream_query["scope"] == "email profile"
    assert upstream_query["organization"] == "org_123"
    assert upstream_query["config_path"] == "/.well-known/openid-configuration"
    assert upstream_query["state"] == "auth0-state-123"

    callback_conn =
      conn(:get, "/auth/callback?code=code-777&state=auth0-state-123")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert callback_conn.status == 302
    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: callback_query} = URI.parse(client_callback_location)

    assert %{"code" => local_code, "state" => "auth0-proxy-state"} =
             URI.decode_query(callback_query)

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
    %{"access_token" => access_token} = Jason.decode!(token_conn.resp_body)

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
                 "name" => "Auth0 User",
                 "sub" => "auth0|user-123"
               },
               "auth" => %{
                 "provider" => "oauth_proxy",
                 "upstream_access_token" => "auth0_access_code-777"
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  test "auth0 domain normalization accepts bare domains" do
    assert Auth0.normalize_auth0_domain("tenant.us.auth0.com") == "https://tenant.us.auth0.com"

    assert Auth0.normalize_auth0_domain("https://tenant.us.auth0.com/") ==
             "https://tenant.us.auth0.com"

    assert Auth0.config_parts(%{
             auth0_domain: "tenant.us.auth0.com",
             client_id: "client",
             client_secret: "secret"
           }) == {"https://tenant.us.auth0.com", nil}
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
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: base_url
      )

    assert authorize_conn.status == 302
    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: base_url
      )

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
    |> FastestMCP.Transport.StreamableHTTP.call(
      server_name: server_name,
      base_url: base_url
    )
  end

  defp register_client(server_name, client_name) do
    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: client_name,
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

  defp s256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
  end
end
