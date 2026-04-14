defmodule FastestMCP.AuthSupabaseProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule UpstreamAuthPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      case conn.request_path do
        "/auth/v1/.well-known/jwks.json" ->
          {_, jwk_map} = opts[:public_jwk]
          send_json(conn, 200, %{"keys" => [Map.put(jwk_map, "kid", "supabase-key-1")]})

        "/auth/v1/.well-known/oauth-authorization-server" ->
          send_json(conn, 200, %{
            issuer: opts[:issuer],
            authorization_endpoint: opts[:issuer] <> "/authorize",
            token_endpoint: opts[:issuer] <> "/token"
          })

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp send_json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end

  test "jwt provider supports JWKS-backed ES256 verification" do
    {public_jwk, private_jwk} = ec_key_pair()
    port = 47_000 + rem(System.unique_integer([:positive]), 1000)
    issuer = "http://127.0.0.1:#{port}/auth/v1"

    start_supervised!(
      {Bandit,
       plug: {UpstreamAuthPlug, public_jwk: public_jwk, issuer: issuer}, scheme: :http, port: port}
    )

    server_name = "jwt-jwks-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.JWT,
        jwks_uri: issuer <> "/.well-known/jwks.json",
        issuer: issuer,
        audience: "authenticated",
        algorithm: "ES256",
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal["sub"] end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => issuer,
        "aud" => "authenticated",
        "exp" => System.os_time(:second) + 3600
      })

    assert "user-123" ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer " <> token}
             )
  end

  test "supabase provider forwards authorization server metadata and validates JWTs from JWKS" do
    {public_jwk, private_jwk} = ec_key_pair()
    port = 48_000 + rem(System.unique_integer([:positive]), 1000)
    project_url = "http://127.0.0.1:#{port}"
    issuer = project_url <> "/auth/v1"

    start_supervised!(
      {Bandit,
       plug: {UpstreamAuthPlug, public_jwk: public_jwk, issuer: issuer}, scheme: :http, port: port}
    )

    server_name = "supabase-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Supabase,
        project_url: project_url,
        base_url: "https://my-server.com",
        required_scopes: ["openid"],
        algorithm: "ES256",
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert metadata_conn.status == 200

    assert %{
             "issuer" => ^issuer,
             "authorization_endpoint" => ^issuer <> "/authorize",
             "token_endpoint" => ^issuer <> "/token"
           } = Jason.decode!(metadata_conn.resp_body)

    protected_resource_conn =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert protected_resource_conn.status == 200

    assert %{
             "authorization_servers" => [^issuer],
             "resource" => "https://my-server.com/mcp"
           } = Jason.decode!(protected_resource_conn.resp_body)

    token =
      sign_token(private_jwk, %{
        "sub" => "supabase-user-123",
        "iss" => issuer,
        "aud" => "authenticated",
        "scope" => "openid email",
        "exp" => System.os_time(:second) + 3600
      })

    protected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert protected_conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{"sub" => "supabase-user-123"},
               "auth" => %{
                 "provider" => "jwt",
                 "issuer" => ^issuer,
                 "subject" => "supabase-user-123"
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  test "supabase helper normalization matches project and auth route expectations" do
    assert FastestMCP.Auth.Supabase.normalize_project_url("https://abc123.supabase.co/") ==
             "https://abc123.supabase.co"

    assert FastestMCP.Auth.Supabase.normalize_auth_route("/custom/auth/route/") ==
             "custom/auth/route"

    assert %{
             jwks_uri: "https://abc123.supabase.co/custom/auth/route/.well-known/jwks.json",
             issuer: "https://abc123.supabase.co/custom/auth/route",
             audience: "authenticated",
             algorithm: "RS256",
             required_scopes: []
           } =
             FastestMCP.Auth.Supabase.jwt_options(%{
               project_url: "https://abc123.supabase.co/",
               auth_route: "/custom/auth/route/",
               algorithm: "RS256"
             })
  end

  defp ec_key_pair do
    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {JOSE.JWK.to_public_map(jwk), jwk}
  end

  defp sign_token(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "supabase-key-1"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
