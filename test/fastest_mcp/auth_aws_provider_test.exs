defmodule FastestMCP.AuthAWSProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.AWS
  alias FastestMCP.Auth.JWT

  @openid_configuration %{
    "issuer" => "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX",
    "authorization_endpoint" => "https://test.auth.us-east-1.amazoncognito.com/oauth2/authorize",
    "token_endpoint" => "https://test.auth.us-east-1.amazoncognito.com/oauth2/token",
    "jwks_uri" =>
      "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX/.well-known/jwks.json",
    "response_types_supported" => ["code"],
    "subject_types_supported" => ["public"],
    "id_token_signing_alg_values_supported" => ["RS256"]
  }

  test "aws cognito wrapper derives discovery url and verifier defaults" do
    opts = %{
      user_pool_id: "us-east-1_XXXXXXXXX",
      aws_region: "us-east-1",
      client_id: "test_client",
      client_secret: "test_secret",
      openid_configuration: @openid_configuration
    }

    assert AWS.config_url(opts) ==
             "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX/.well-known/openid-configuration"

    assert %{
             jwks_uri:
               "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX/.well-known/jwks.json",
             issuer: "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX",
             audience: nil,
             required_claims: %{"client_id" => "test_client"},
             required_scopes: ["openid"]
           } = AWS.token_verifier_options(opts)
  end

  test "aws cognito wrapper defaults region and still allows explicit audience override" do
    opts = %{
      user_pool_id: "us-east-1_XXXXXXXXX",
      client_id: "test_client",
      client_secret: "test_secret",
      audience: "custom-audience",
      openid_configuration: @openid_configuration
    }

    assert AWS.config_url(opts) ==
             "https://cognito-idp.eu-central-1.amazonaws.com/us-east-1_XXXXXXXXX/.well-known/openid-configuration"

    assert AWS.token_verifier_options(opts).audience == "custom-audience"
    assert AWS.token_verifier_options(opts).required_claims == %{"client_id" => "test_client"}
  end

  test "aws cognito verifier accepts access tokens using client_id claim instead of aud" do
    {public_key, private_jwk} = rsa_key_pair()

    opts = %{
      user_pool_id: "us-east-1_XXXXXXXXX",
      aws_region: "us-east-1",
      client_id: "test_client",
      client_secret: "test_secret",
      openid_configuration: @openid_configuration
    }

    verifier_opts =
      opts
      |> AWS.token_verifier_options()
      |> Map.put(:public_key, public_key)

    valid_access_token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => @openid_configuration["issuer"],
        "client_id" => "test_client",
        "scope" => "openid profile",
        "exp" => System.os_time(:second) + 3600
      })

    assert {:ok, %{"sub" => "user-123"}} = JWT.verify(valid_access_token, verifier_opts)

    wrong_client_token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => @openid_configuration["issuer"],
        "client_id" => "other_client",
        "scope" => "openid",
        "exp" => System.os_time(:second) + 3600
      })

    assert {:error, %FastestMCP.Error{code: :unauthorized}} =
             JWT.verify(wrong_client_token, verifier_opts)
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
end
