defmodule FastestMCP.AuthHTTPClientParityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Azure
  alias FastestMCP.Auth.Discord
  alias FastestMCP.Auth.DiscordToken
  alias FastestMCP.Auth.Introspection
  alias FastestMCP.Auth.JWT
  alias FastestMCP.Auth.OIDC
  alias FastestMCP.Error

  test "introspection verifier uses provided http_client requester" do
    requester = fn :post, url, opts ->
      send(self(), {:introspection_request, url, opts})

      {:ok, 200, [{"content-type", "application/json"}],
       Jason.encode!(%{
         "active" => true,
         "client_id" => "service-123",
         "sub" => "user-123",
         "scope" => "tools:call resources:read",
         "exp" => System.os_time(:second) + 3600
       })}
    end

    assert {:ok, result} =
             Introspection.authenticate(
               %{"authorization" => "Bearer opaque-token"},
               nil,
               %{
                 introspection_url: "https://auth.example.com/oauth/introspect",
                 client_id: "client-id",
                 client_secret: "client-secret",
                 ssrf_safe: false,
                 http_client: requester
               }
             )

    assert result.auth.provider == :introspection
    assert result.auth.client_id == "service-123"
    assert result.capabilities == ["tools:call", "resources:read"]

    assert_receive {:introspection_request, "https://auth.example.com/oauth/introspect", opts}
    assert opts[:form]["token"] == "opaque-token"
    assert opts[:form]["token_type_hint"] == "access_token"

    assert Enum.any?(opts[:headers], fn
             {"authorization", "Basic " <> _encoded} -> true
             _other -> false
           end)
  end

  test "jwt verifier uses provided http_client requester for non-ssrf jwks fetches" do
    {public_key, private_jwk} = rsa_key_pair()

    jwks_uri =
      "https://auth.example.com/.well-known/jwks-#{System.unique_integer([:positive])}.json"

    requester = fn :get, url, opts ->
      send(self(), {:jwks_request, url, opts})

      {:ok, 200, [{"content-type", "application/json"}],
       Jason.encode!(%{"keys" => [public_jwk_map(public_key)]})}
    end

    token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => "https://auth.example.com",
        "exp" => System.os_time(:second) + 3600
      })

    assert {:ok, %{"sub" => "user-123"}} =
             JWT.verify(token, %{
               jwks_uri: jwks_uri,
               issuer: "https://auth.example.com",
               ssrf_safe: false,
               http_client: requester
             })

    assert_receive {:jwks_request, ^jwks_uri, opts}
    assert opts[:timeout_ms] == 5_000
  end

  test "jwt verifier rejects http_client with ssrf_safe jwks fetches" do
    error =
      assert_raise Error, fn ->
        verify_or_raise!("token", %{
          jwks_uri: "https://auth.example.com/.well-known/jwks.json",
          ssrf_safe: true,
          http_client: fn _, _, _ -> flunk("should not run") end
        })
      end

    assert error.code == :internal_error
    assert error.message =~ "http_client cannot be used with ssrf_safe jwks_uri"
  end

  test "jwt verifier allows http_client with static public keys" do
    {public_key, private_jwk} = rsa_key_pair()

    token =
      sign_token(private_jwk, %{
        "sub" => "static-user",
        "iss" => "https://issuer.example.com",
        "exp" => System.os_time(:second) + 3600
      })

    assert {:ok, %{"sub" => "static-user"}} =
             JWT.verify(token, %{
               public_key: public_key,
               issuer: "https://issuer.example.com",
               ssrf_safe: true,
               http_client: fn _, _, _ -> flunk("static keys should not issue HTTP requests") end
             })
  end

  test "discord token verifier uses provided http_client requester" do
    requester = fn :get, url, opts ->
      send(self(), {:discord_request, url, opts})

      {:ok, 200, [{"content-type", "application/json"}],
       Jason.encode!(%{
         "application" => %{"id" => "discord-app-id"},
         "user" => %{"id" => "user-123", "username" => "wumpus"},
         "scopes" => ["identify", "email"],
         "expires" => DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.to_iso8601()
       })}
    end

    assert {:ok, result} =
             DiscordToken.authenticate(
               %{"authorization" => "Bearer discord-token"},
               nil,
               %{
                 expected_client_id: "discord-app-id",
                 api_base_url: "https://discord.com",
                 http_client: requester
               }
             )

    assert result.auth.provider == :discord
    assert result.auth.subject == "user-123"
    assert result.capabilities == ["identify", "email"]

    assert_receive {:discord_request, "https://discord.com/api/oauth2/@me", opts}
    assert {"authorization", "Bearer discord-token"} in opts[:headers]
  end

  test "oidc and wrapper token verifier options thread http_client through" do
    requester = fn _, _, _ -> flunk("requester should not run in option tests") end

    oidc_opts =
      OIDC.token_verifier_options(%{
        config_url: "https://issuer.example.com/.well-known/openid-configuration",
        client_id: "client-id",
        client_secret: "client-secret",
        openid_configuration: %{
          "issuer" => "https://issuer.example.com",
          "authorization_endpoint" => "https://issuer.example.com/authorize",
          "token_endpoint" => "https://issuer.example.com/token",
          "jwks_uri" => "https://issuer.example.com/jwks",
          "response_types_supported" => ["code"],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["RS256"]
        },
        http_client: requester
      })

    assert oidc_opts.http_client == requester

    azure_opts =
      Azure.token_verifier_options(%{
        client_id: "azure-client-id",
        client_secret: "azure-client-secret",
        tenant_id: "tenant-id",
        http_client: requester
      })

    assert azure_opts.http_client == requester

    discord_opts =
      Discord.token_verifier_options(%{
        client_id: "discord-client-id",
        http_client: requester
      })

    assert discord_opts.http_client == requester
  end

  defp verify_or_raise!(token, opts) do
    case JWT.verify(token, opts) do
      {:ok, claims} -> claims
      {:error, %Error{} = error} -> raise error
    end
  end

  defp rsa_key_pair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {public_pem, jwk}
  end

  defp public_jwk_map(public_key) do
    public_key
    |> JOSE.JWK.from_pem()
    |> JOSE.JWK.to_public_map()
    |> elem(1)
    |> Map.put("kid", "test-key-1")
    |> Map.put("use", "sig")
    |> Map.put("alg", "RS256")
  end

  defp sign_token(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key-1"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
