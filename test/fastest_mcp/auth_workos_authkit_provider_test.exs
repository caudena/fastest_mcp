defmodule FastestMCP.AuthWorkOSAuthKitProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth.WorkOSAuthKit

  test "authkit provider derives JWT audience from advertised resource URL" do
    parent = self()
    {public_jwks, private_jwk} = rsa_key_pair()
    authkit_domain = "https://tenant.authkit.app"

    server_name =
      "workos-authkit-audience-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.WorkOSAuthKit,
        authkit_domain: authkit_domain,
        required_scopes: ["openid"],
        jwks_fetcher: fn url ->
          send(parent, {:jwks_url, url})
          {:ok, Enum.map(public_jwks["keys"], &JOSE.JWK.from_map/1)}
        end
      )
      |> FastestMCP.add_tool("whoami", fn _arguments, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    metadata_conn =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert metadata_conn.status == 200

    assert %{
             "resource" => "https://mcp.example.com/mcp",
             "authorization_servers" => [^authkit_domain],
             "scopes_supported" => ["openid"]
           } = Jason.decode!(metadata_conn.resp_body)

    access_token =
      sign_token(private_jwk, %{
        "sub" => "user_123",
        "iss" => authkit_domain,
        "aud" => "https://mcp.example.com/mcp",
        "scope" => "openid profile",
        "exp" => System.os_time(:second) + 3600
      })

    protected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert protected_conn.status == 200
    assert_receive {:jwks_url, "https://tenant.authkit.app/oauth2/jwks"}

    assert %{
             "structuredContent" => %{
               "principal" => %{"sub" => "user_123"},
               "auth" => %{
                 "provider" => "jwt",
                 "issuer" => ^authkit_domain,
                 "subject" => "user_123",
                 "scopes" => ["openid", "profile"]
               }
             }
           } = Jason.decode!(protected_conn.resp_body)

    wrong_audience =
      sign_token(private_jwk, %{
        "sub" => "user_123",
        "iss" => authkit_domain,
        "aud" => "https://other.example.com/mcp",
        "scope" => "openid",
        "exp" => System.os_time(:second) + 3600
      })

    rejected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> wrong_audience)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert rejected_conn.status == 401
  end

  test "authkit provider preserves explicit audience and token verifier overrides" do
    opts = %{
      authkit_domain: "tenant.authkit.app",
      base_url: "https://mcp.example.com",
      audience: "custom-audience",
      required_scopes: "openid email"
    }

    assert %{
             jwks_uri: "https://tenant.authkit.app/oauth2/jwks",
             issuer: "https://tenant.authkit.app",
             audience: "custom-audience",
             required_scopes: ["openid", "email"]
           } = WorkOSAuthKit.token_verifier_options(opts)

    server_name =
      "workos-authkit-custom-verifier-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.WorkOSAuthKit,
        authkit_domain: "tenant.authkit.app",
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"opaque" => %{client_id: "static-client"}}}
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "echo", "arguments" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer opaque")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200
  end

  test "authkit provider forwards authorization-server metadata through a fetcher" do
    parent = self()

    server_name =
      "workos-authkit-metadata-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.WorkOSAuthKit,
        authkit_domain: "https://tenant.authkit.app",
        metadata_fetcher: fn url ->
          send(parent, {:metadata_url, url})
          %{"issuer" => "https://tenant.authkit.app", "registration_endpoint" => url}
        end,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"opaque" => %{client_id: "static-client"}}}
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert_receive {:metadata_url,
                    "https://tenant.authkit.app/.well-known/oauth-authorization-server"}

    assert %{
             "issuer" => "https://tenant.authkit.app",
             "registration_endpoint" =>
               "https://tenant.authkit.app/.well-known/oauth-authorization-server"
           } = Jason.decode!(conn.resp_body)
  end

  defp rsa_key_pair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    public_jwk = JOSE.JWK.to_public(jwk)
    {_fields, jwk_map} = JOSE.JWK.to_map(public_jwk)
    {%{"keys" => [jwk_map]}, jwk}
  end

  defp sign_token(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
