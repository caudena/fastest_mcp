defmodule FastestMCP.Auth.PrivateKeyJWT do
  @moduledoc """
  Helpers for OAuth private-key JWT client authentication.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  alias FastestMCP.Auth.JWT
  alias FastestMCP.Auth.StateStore
  alias FastestMCP.Error

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @allowed_algorithms ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)
  @max_assertion_lifetime 300
  @clock_skew_seconds 30

  @doc "Returns the OAuth assertion type handled by this module."
  def assertion_type, do: @assertion_type
  @doc "Returns the JOSE algorithms supported for private-key JWT assertions."
  def supported_algorithms, do: @allowed_algorithms

  @doc "Validates the given value for this module."
  def validate(assertion, client_id, token_endpoint, cimd_document, replay_store, opts \\ [])
      when is_binary(assertion) and is_binary(client_id) and is_binary(token_endpoint) do
    with {:ok, algorithm} <- peek_algorithm(assertion),
         {:ok, jwt_opts} <-
           verification_opts(cimd_document, algorithm, client_id, token_endpoint, opts),
         {:ok, claims} <- JWT.verify(assertion, jwt_opts),
         :ok <- validate_lifetime(claims),
         :ok <- validate_subject(claims, client_id),
         :ok <- validate_jti(claims, client_id, replay_store) do
      {:ok, claims}
    else
      {:error, %Error{message: message}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  defp peek_algorithm(assertion) do
    with header when is_binary(header) <- JOSE.JWS.peek_protected(assertion),
         {:ok, %{"alg" => algorithm}} <- Jason.decode(header),
         true <- algorithm in @allowed_algorithms do
      {:ok, algorithm}
    else
      _ -> {:error, "invalid JWT assertion"}
    end
  rescue
    _error -> {:error, "invalid JWT assertion"}
  end

  defp verification_opts(cimd_document, algorithm, client_id, token_endpoint, opts)
       when is_map(cimd_document) do
    base_opts = [
      algorithm: algorithm,
      issuer: client_id,
      audience: token_endpoint
    ]

    cond do
      jwks_uri = fetch(cimd_document, "jwks_uri") ->
        {:ok,
         base_opts
         |> Keyword.put(:jwks_uri, jwks_uri)
         |> maybe_put(:jwks_fetcher, Keyword.get(opts, :jwks_fetcher))
         |> maybe_put(:jwks_timeout_ms, Keyword.get(opts, :jwks_timeout_ms))
         |> maybe_put(:jwks_cache_ttl_ms, Keyword.get(opts, :jwks_cache_ttl_ms))
         |> maybe_put(:ssrf_safe, Keyword.get(opts, :ssrf_safe, true))
         |> maybe_put(:ssrf_resolver, Keyword.get(opts, :ssrf_resolver))
         |> maybe_put(:ssrf_requester, Keyword.get(opts, :ssrf_requester))
         |> maybe_put(:ssrf_max_size_bytes, Keyword.get(opts, :ssrf_max_size_bytes))
         |> maybe_put(:ssrf_overall_timeout_ms, Keyword.get(opts, :ssrf_overall_timeout_ms))}

      jwks = fetch(cimd_document, "jwks") ->
        {:ok, Keyword.put(base_opts, :jwks, jwks)}

      true ->
        {:error, "CIMD document must provide jwks_uri or jwks for private_key_jwt"}
    end
  end

  defp verification_opts(_cimd_document, _algorithm, _client_id, _token_endpoint, _opts) do
    {:error, "client metadata is required for private_key_jwt"}
  end

  defp validate_lifetime(%{"exp" => exp} = claims) when is_integer(exp) do
    now = System.os_time(:second)

    cond do
      exp < now - @clock_skew_seconds ->
        {:error, "assertion has expired"}

      iat = claims["iat"] ->
        validate_iat_and_exp(iat, exp, now)

      exp > now + @max_assertion_lifetime ->
        {:error, "assertion exp is too far in the future"}

      true ->
        :ok
    end
  end

  defp validate_lifetime(_claims), do: {:error, "assertion must include exp claim"}

  defp validate_iat_and_exp(iat, exp, now) when is_integer(iat) do
    cond do
      iat > now + @clock_skew_seconds ->
        {:error, "assertion iat is in the future"}

      exp - iat > @max_assertion_lifetime ->
        {:error, "assertion lifetime is too long"}

      true ->
        :ok
    end
  end

  defp validate_iat_and_exp(_iat, _exp, _now), do: {:error, "assertion iat is invalid"}

  defp validate_subject(%{"sub" => subject}, client_id) when subject == client_id, do: :ok

  defp validate_subject(_claims, _client_id),
    do: {:error, "assertion sub claim must match client_id"}

  defp validate_jti(%{"jti" => jti, "exp" => exp}, client_id, replay_store)
       when is_binary(jti) and is_integer(exp) do
    key = "jti:" <> client_id <> ":" <> jti

    case StateStore.get(replay_store, key) do
      {:ok, _value} ->
        {:error, "assertion replay detected"}

      {:error, :not_found} ->
        ttl_ms = max(exp - System.os_time(:second), 1) * 1_000
        :ok = StateStore.put(replay_store, key, true, ttl_ms)
        :ok
    end
  end

  defp validate_jti(_claims, _client_id, _replay_store),
    do: {:error, "assertion must include jti claim"}

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
