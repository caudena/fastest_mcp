defmodule FastestMCP.AuthOCIProviderTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Auth.OCI

  test "oci provider builds oidc verifier options from inline configuration" do
    opts = %{
      config_url: "https://idcs.example.com/.well-known/openid-configuration",
      client_id: "oci-client",
      client_secret: "oci-secret",
      oidc_scopes: ["openid", "urn:opc:idm:__myscopes__"],
      audience: "resource-audience",
      required_scopes: ["tools:call"],
      openid_configuration: openid_configuration()
    }

    verifier_opts = OCI.token_verifier_options(opts)

    assert verifier_opts.jwks_uri == "https://idcs.example.com/admin/v1/SigningCert/jwk"
    assert verifier_opts.issuer == "https://idcs.example.com"
    assert verifier_opts.audience == "resource-audience"
    assert verifier_opts.required_scopes == ["tools:call"]
  end

  defp openid_configuration do
    %{
      "issuer" => "https://idcs.example.com",
      "authorization_endpoint" => "https://idcs.example.com/oauth2/v1/authorize",
      "token_endpoint" => "https://idcs.example.com/oauth2/v1/token",
      "jwks_uri" => "https://idcs.example.com/admin/v1/SigningCert/jwk",
      "response_types_supported" => ["code"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"]
    }
  end
end
