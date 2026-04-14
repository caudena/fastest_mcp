defmodule FastestMCP.Auth.JWT do
  @moduledoc """
  JOSE-backed JWT bearer token verifier.

  Supports symmetric and asymmetric verification from inline key material and
  validates issuer, audience, expiry, not-before, and required scopes.

  Optional network overrides:

  - `:http_client` / `:http_requester` - custom requester used for non-SSRF
    JWKS fetches
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.JWKSCache
  alias FastestMCP.Auth.Result
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.Error
  alias FastestMCP.HTTP

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, _context, opts) do
    with {:ok, token} <- fetch_token(input),
         {:ok, claims} <- verify(token, opts),
         scopes = scopes_from_claims(claims),
         :ok <- validate_required_scopes(scopes, opts) do
      {:ok,
       %Result{
         principal: claims,
         auth: %{
           provider: :jwt,
           subject: claims["sub"],
           issuer: claims["iss"],
           scopes: scopes
         },
         capabilities: scopes
       }}
    end
  end

  @doc "Verifies the given token."
  def verify(token, opts) when is_binary(token) do
    with {:ok, signer} <- signer(opts, token),
         {:ok, claims} <- verify_token(token, signer, opts) do
      {:ok, claims}
    end
  end

  defp verify_token(token, {:static, jwk, algorithms}, opts),
    do: verify_with_signers(token, [jwk], algorithms, opts)

  defp verify_token(token, {:jwks, jwks, algorithms}, opts),
    do: verify_with_signers(token, jwks, algorithms, opts)

  defp verify_with_signers(token, signers, algorithms, opts) do
    signers
    |> Enum.find_value(fn jwk ->
      case JOSE.JWT.verify_strict(jwk, algorithms, token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, normalize_claims(claims)}
        _ -> nil
      end
    end)
    |> case do
      {:ok, claims} ->
        with :ok <- validate_issuer(claims, opts),
             :ok <- validate_audience(claims, opts),
             :ok <- validate_expiration(claims),
             :ok <- validate_not_before(claims) do
          {:ok, claims}
        end

      nil ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
    end
  rescue
    _error ->
      {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
  end

  defp signer(opts, _token) do
    algorithm = opt(opts, :algorithm, "RS256")

    cond do
      hs_algorithm?(algorithm) ->
        secret = opt(opts, :public_key)

        cond do
          is_nil(secret) ->
            {:error,
             %Error{
               code: :internal_error,
               message: "jwt auth requires public_key for symmetric algorithms"
             }}

          pem_key?(secret) ->
            {:error,
             %Error{
               code: :internal_error,
               message: "jwt auth shared-secret algorithms require non-PEM key material"
             }}

          true ->
            {:ok, {:static, JOSE.JWK.from_oct(secret), [algorithm]}}
        end

      public_key = opt(opts, :public_key) ->
        {:ok, {:static, JOSE.JWK.from_pem(public_key), [algorithm]}}

      jwks = opt(opts, :jwks) ->
        with {:ok, parsed_jwks} <- parse_jwks(jwks) do
          {:ok, {:jwks, parsed_jwks, [algorithm]}}
        else
          {:error, reason} ->
            {:error,
             %Error{
               code: :internal_error,
               message: "failed to load jwks",
               details: %{reason: inspect(reason)}
             }}
        end

      jwks_uri = opt(opts, :jwks_uri) ->
        jwks_signer(jwks_uri, algorithm, opts)

      true ->
        {:error,
         %Error{
           code: :internal_error,
           message: "jwt auth requires public_key key material"
         }}
    end
  end

  defp jwks_signer(jwks_uri, algorithm, opts) do
    if hs_algorithm?(algorithm) do
      {:error,
       %Error{
         code: :internal_error,
         message: "jwt auth jwks_uri cannot be used with symmetric algorithms"
       }}
    else
      if ssrf_safe_http_client_conflict?(opts) do
        {:error,
         %Error{
           code: :internal_error,
           message: "jwt auth http_client cannot be used with ssrf_safe jwks_uri"
         }}
      else
        ttl_ms = opt(opts, :jwks_cache_ttl_ms, 300_000)

        fetcher = fn ->
          case opt(opts, :jwks_fetcher) do
            nil -> fetch_jwks(jwks_uri, opts)
            custom when is_function(custom, 1) -> custom.(jwks_uri)
          end
        end

        with {:ok, jwks} <- JWKSCache.fetch(jwks_uri, ttl_ms, fetcher) do
          {:ok, {:jwks, jwks, [algorithm]}}
        else
          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error,
             %Error{
               code: :internal_error,
               message: "failed to load jwks",
               details: %{reason: inspect(reason), jwks_uri: jwks_uri}
             }}
        end
      end
    end
  end

  defp ssrf_safe_http_client_conflict?(opts) do
    opt(opts, :ssrf_safe, true) and
      is_nil(opt(opts, :jwks_fetcher)) and
      not is_nil(http_requester(opts))
  end

  defp http_requester(opts) do
    opt(opts, :http_requester) || opt(opts, :http_client)
  end

  defp fetch_jwks(jwks_uri, opts) do
    timeout_ms = opt(opts, :jwks_timeout_ms, 5_000)

    with {:ok, payload} <- fetch_remote_json(jwks_uri, timeout_ms, opts),
         {:ok, jwks} <- parse_jwks(payload) do
      {:ok, jwks}
    else
      {:error, {:http_status, status, body}} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to fetch jwks",
           details: %{jwks_uri: jwks_uri, status: status, body: body}
         }}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to fetch jwks",
           details: %{jwks_uri: jwks_uri, reason: inspect(reason)}
         }}
    end
  end

  defp fetch_remote_json(url, timeout_ms, opts) do
    case opt(opts, :jwks_fetcher) do
      custom when is_function(custom, 1) ->
        custom.(url)

      nil ->
        if opt(opts, :ssrf_safe, true) do
          SSRF.get_json(url,
            timeout_ms: timeout_ms,
            overall_timeout_ms: opt(opts, :ssrf_overall_timeout_ms, 30_000),
            max_size_bytes: opt(opts, :ssrf_max_size_bytes, 5_120),
            resolver: opt(opts, :ssrf_resolver),
            requester: opt(opts, :ssrf_requester)
          )
        else
          HTTP.get_json(url, timeout_ms: timeout_ms, requester: http_requester(opts))
        end
    end
  end

  defp parse_jwks(%{"keys" => keys}) when is_list(keys) and keys != [] do
    {:ok, Enum.map(keys, &JOSE.JWK.from_map/1)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_jwks(map) when is_map(map) do
    {:ok, [JOSE.JWK.from_map(map)]}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_jwks(_payload), do: {:error, "jwks payload must be an object with keys"}

  defp fetch_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token(%{"authorization" => "Bearer " <> token}), do: {:ok, token}
  defp fetch_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: {:ok, token}

  defp fetch_token(_input),
    do: {:error, %Error{code: :unauthorized, message: "missing credentials"}}

  defp validate_issuer(claims, opts) do
    case opt(opts, :issuer) do
      issuer when issuer in [nil, []] ->
        :ok

      issuer ->
        if claims["iss"] == issuer do
          :ok
        else
          {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
        end
    end
  end

  defp validate_audience(claims, opts) do
    case opt(opts, :audience) do
      audience when audience in [nil, []] ->
        :ok

      audience ->
        token_audiences =
          claims["aud"]
          |> List.wrap()
          |> Enum.map(&to_string/1)

        expected_audiences =
          audience
          |> List.wrap()
          |> Enum.map(&to_string/1)

        if Enum.any?(expected_audiences, &(&1 in token_audiences)) do
          :ok
        else
          {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
        end
    end
  end

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second) do
      :ok
    else
      {:error, %Error{code: :unauthorized, message: "token expired"}}
    end
  end

  defp validate_expiration(_claims), do: :ok

  defp validate_not_before(%{"nbf" => nbf}) when is_integer(nbf) do
    if nbf <= System.os_time(:second) do
      :ok
    else
      {:error, %Error{code: :unauthorized, message: "token is not active yet"}}
    end
  end

  defp validate_not_before(_claims), do: :ok

  defp validate_required_scopes(scopes, opts) do
    required_scopes =
      opts
      |> opt(:required_scopes, [])
      |> List.wrap()

    missing_scopes = required_scopes -- scopes

    if missing_scopes == [] do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "insufficient scope",
         details: %{missing_scopes: missing_scopes}
       }}
    end
  end

  defp scopes_from_claims(claims) do
    cond do
      is_binary(claims["scope"]) ->
        claims["scope"]
        |> String.split(~r/\s+/, trim: true)

      is_binary(claims["scp"]) ->
        claims["scp"]
        |> String.split(~r/\s+/, trim: true)

      is_list(claims["scp"]) ->
        claims["scp"]

      true ->
        []
    end
  end

  defp normalize_claims(claims) when is_map(claims) do
    Map.new(claims, fn {key, value} ->
      {to_string(key), value}
    end)
  end

  defp hs_algorithm?(algorithm), do: String.starts_with?(to_string(algorithm), "HS")
  defp pem_key?(value) when is_binary(value), do: String.contains?(value, "BEGIN ")
  defp pem_key?(_value), do: false

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
end
