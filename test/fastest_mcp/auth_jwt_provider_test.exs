defmodule FastestMCP.AuthJWTProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error

  test "jwt provider accepts valid RSA tokens and exposes claims on context" do
    {public_key, private_jwk} = rsa_key_pair()
    server_name = "jwt-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.JWT,
        public_key: public_key,
        issuer: "https://issuer.example.com",
        audience: "https://api.example.com"
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth, capabilities: ctx.capabilities}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => "https://issuer.example.com",
        "aud" => "https://api.example.com",
        "scope" => "tools:call resources:read",
        "exp" => System.os_time(:second) + 3600
      })

    assert %{
             principal: %{"sub" => "user-123"},
             auth: %{
               issuer: "https://issuer.example.com",
               provider: :jwt,
               scopes: ["tools:call", "resources:read"],
               subject: "user-123"
             },
             capabilities: ["tools:call", "resources:read"]
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer " <> token}
             )
  end

  test "jwt provider rejects invalid issuer and insufficient scopes" do
    {public_key, private_jwk} = rsa_key_pair()
    server_name = "jwt-auth-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.JWT,
        public_key: public_key,
        issuer: "https://issuer.example.com",
        audience: "https://api.example.com",
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    wrong_issuer_token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => "https://evil.example.com",
        "aud" => "https://api.example.com",
        "scope" => "tools:call",
        "exp" => System.os_time(:second) + 3600
      })

    issuer_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer " <> wrong_issuer_token}
        )
      end

    assert issuer_error.code == :unauthorized

    wrong_scope_token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => "https://issuer.example.com",
        "aud" => "https://api.example.com",
        "scope" => "resources:read",
        "exp" => System.os_time(:second) + 3600
      })

    scope_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer " <> wrong_scope_token}
        )
      end

    assert scope_error.code == :forbidden
    assert scope_error.details[:missing_scopes] == ["tools:call"]
  end

  test "jwt provider supports symmetric HS256 verification" do
    server_name = "jwt-auth-hs-" <> Integer.to_string(System.unique_integer([:positive]))
    secret = "test-secret-key"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.JWT,
        public_key: secret,
        algorithm: "HS256",
        issuer: "https://issuer.example.com"
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal["sub"] end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    token =
      sign_hs_token(secret, %{
        "sub" => "service-123",
        "iss" => "https://issuer.example.com",
        "exp" => System.os_time(:second) + 3600
      })

    assert "service-123" ==
             FastestMCP.call_tool(server_name, "whoami", %{}, auth_input: %{"token" => token})
  end

  defp rsa_key_pair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {public_pem, jwk}
  end

  defp sign_token(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp sign_hs_token(secret, claims) do
    {_, token} =
      JOSE.JWK.from_oct(secret)
      |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
