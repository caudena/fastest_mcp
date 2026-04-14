defmodule FastestMCP.AuthAWSProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.AWS

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
             audience: "test_client",
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
  end
end
