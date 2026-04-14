defmodule FastestMCP.AuthJWTIssuerTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.JWTIssuer

  test "derive_jwt_key returns deterministic 32-byte base64url keys" do
    high_entropy_key =
      JWTIssuer.derive_jwt_key(
        high_entropy_material: "test-secret",
        salt: "test-salt"
      )

    low_entropy_key =
      JWTIssuer.derive_jwt_key(
        low_entropy_material: "test-secret",
        salt: "test-salt"
      )

    assert byte_size(high_entropy_key) == 44
    assert byte_size(low_entropy_key) == 44
    assert {:ok, decoded_high} = Base.url_decode64(high_entropy_key)
    assert {:ok, decoded_low} = Base.url_decode64(low_entropy_key)
    assert byte_size(decoded_high) == 32
    assert byte_size(decoded_low) == 32

    assert high_entropy_key ==
             JWTIssuer.derive_jwt_key(
               high_entropy_material: "test-secret",
               salt: "test-salt"
             )

    assert low_entropy_key ==
             JWTIssuer.derive_jwt_key(
               low_entropy_material: "test-secret",
               salt: "test-salt"
             )
  end

  test "issuer creates and verifies access and refresh tokens" do
    signing_key =
      JWTIssuer.derive_jwt_key(
        low_entropy_material: "test-secret",
        salt: "test-salt"
      )

    issuer =
      JWTIssuer.new(
        issuer: "https://test-server.com",
        audience: "https://test-server.com/mcp",
        signing_key: signing_key
      )

    access_token =
      JWTIssuer.issue_access_token(issuer,
        client_id: "client-abc",
        scopes: ["read", "write"],
        jti: "token-id-123",
        expires_in: 3600
      )

    refresh_token =
      JWTIssuer.issue_refresh_token(issuer,
        client_id: "client-abc",
        scopes: ["read"],
        jti: "refresh-token-id",
        expires_in: 3600,
        upstream_claims: %{"sub" => "user-123"}
      )

    access_payload = JWTIssuer.verify_token(issuer, access_token)
    refresh_payload = JWTIssuer.verify_token(issuer, refresh_token, expected_token_use: "refresh")

    assert access_payload["client_id"] == "client-abc"
    assert access_payload["scope"] == "read write"
    assert access_payload["jti"] == "token-id-123"
    assert access_payload["iss"] == "https://test-server.com"
    assert access_payload["aud"] == "https://test-server.com/mcp"
    refute Map.has_key?(access_payload, "upstream_claims")

    assert refresh_payload["token_use"] == "refresh"
    assert refresh_payload["upstream_claims"] == %{"sub" => "user-123"}

    assert_raise JWTIssuer.VerificationError, ~r/Token type mismatch/, fn ->
      JWTIssuer.verify_token(issuer, refresh_token)
    end
  end

  test "issuer rejects expired, wrong-issuer, and wrong-audience tokens" do
    signing_key =
      JWTIssuer.derive_jwt_key(
        low_entropy_material: "test-secret",
        salt: "test-salt"
      )

    issuer =
      JWTIssuer.new(
        issuer: "https://test-server.com",
        audience: "https://test-server.com/mcp",
        signing_key: signing_key
      )

    expired_token =
      JWTIssuer.issue_access_token(issuer,
        client_id: "client-abc",
        scopes: ["read"],
        jti: "expired-token",
        expires_in: -1
      )

    assert_raise JWTIssuer.VerificationError, ~r/expired/, fn ->
      JWTIssuer.verify_token(issuer, expired_token)
    end

    wrong_issuer =
      JWTIssuer.new(
        issuer: "https://other-server.com",
        audience: "https://test-server.com/mcp",
        signing_key: signing_key
      )

    token =
      JWTIssuer.issue_access_token(issuer,
        client_id: "client-abc",
        scopes: ["read"],
        jti: "token-id"
      )

    assert_raise JWTIssuer.VerificationError, ~r/issuer/, fn ->
      JWTIssuer.verify_token(wrong_issuer, token)
    end

    wrong_audience =
      JWTIssuer.new(
        issuer: "https://test-server.com",
        audience: "https://other-server.com/mcp",
        signing_key: signing_key
      )

    assert_raise JWTIssuer.VerificationError, ~r/audience/, fn ->
      JWTIssuer.verify_token(wrong_audience, token)
    end
  end
end
