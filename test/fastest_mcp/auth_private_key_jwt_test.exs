defmodule FastestMCP.AuthPrivateKeyJWTTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Auth.PrivateKeyJWT
  alias FastestMCP.Auth.StateStore

  test "valid inline jwks assertions verify and replayed jtis are rejected" do
    {:ok, replay_store} = StateStore.start_link(ttl_ms: 60_000)
    {private_jwk, public_jwks} = rsa_key_pair()
    client_id = "https://example.com/client.json"
    token_endpoint = "https://mcp.example.com/token"

    assertion =
      client_assertion(private_jwk, client_id, token_endpoint,
        jti: "private-key-jwt-1",
        kid: "test-key-1"
      )

    assert {:ok, %{"sub" => ^client_id}} =
             PrivateKeyJWT.validate(
               assertion,
               client_id,
               token_endpoint,
               %{"jwks" => public_jwks},
               replay_store
             )

    assert {:error, reason} =
             PrivateKeyJWT.validate(
               assertion,
               client_id,
               token_endpoint,
               %{"jwks" => public_jwks},
               replay_store
             )

    assert reason =~ "replay"
  end

  test "assertions with excessive lifetime are rejected" do
    {:ok, replay_store} = StateStore.start_link(ttl_ms: 60_000)
    {private_jwk, public_jwks} = rsa_key_pair()
    client_id = "https://example.com/client.json"
    token_endpoint = "https://mcp.example.com/token"

    assertion =
      client_assertion(private_jwk, client_id, token_endpoint,
        jti: "private-key-jwt-too-long",
        kid: "test-key-1",
        expires_in_seconds: 600,
        iat: System.os_time(:second)
      )

    assert {:error, reason} =
             PrivateKeyJWT.validate(
               assertion,
               client_id,
               token_endpoint,
               %{"jwks" => public_jwks},
               replay_store
             )

    assert reason =~ "lifetime"
  end

  defp rsa_key_pair do
    private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    public_jwk = JOSE.JWK.to_public(private_jwk)
    {_fields, jwk_map} = JOSE.JWK.to_map(public_jwk)
    {private_jwk, %{"keys" => [jwk_map]}}
  end

  defp client_assertion(private_jwk, client_id, token_endpoint, opts) do
    now = System.os_time(:second)

    claims =
      %{
        "iss" => client_id,
        "sub" => client_id,
        "aud" => token_endpoint,
        "exp" => now + Keyword.get(opts, :expires_in_seconds, 60),
        "jti" => Keyword.fetch!(opts, :jti)
      }
      |> maybe_put("iat", Keyword.get(opts, :iat, now))

    headers = %{"alg" => "RS256", "kid" => Keyword.get(opts, :kid, "test-key-1")}

    JOSE.JWT.sign(private_jwk, headers, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
