defmodule FastestMCP.Auth.JWTIssuer do
  @moduledoc """
  HS256 JWT token factory for the local OAuth server path.

  This mirrors the Python replacement contract closely enough to issue minimal
  reference-style access and refresh tokens while keeping verification logic
  self-contained for tests and future runtime use.
  """

  alias Plug.Crypto.KeyGenerator

  @default_low_entropy_iterations 1_000_000
  @default_hkdf_info "Fernet"

  defmodule VerificationError do
    @moduledoc """
    Raised when a token issued by this module fails verification.
    """

    defexception [:message]
  end

  defstruct [:issuer, :audience, :signing_key]

  @doc "Builds a new value for this module from the supplied options."
  def new(opts) do
    %__MODULE__{
      issuer: Keyword.fetch!(opts, :issuer) |> to_string(),
      audience: Keyword.fetch!(opts, :audience) |> to_string(),
      signing_key: normalize_signing_key(Keyword.fetch!(opts, :signing_key))
    }
  end

  @doc "Derives a JWT signing key from high-entropy or low-entropy source material."
  def derive_jwt_key(opts) when is_list(opts) do
    high_entropy_material = Keyword.get(opts, :high_entropy_material)
    low_entropy_material = Keyword.get(opts, :low_entropy_material)
    salt = Keyword.fetch!(opts, :salt) |> to_string()

    cond do
      not is_nil(high_entropy_material) and not is_nil(low_entropy_material) ->
        raise ArgumentError,
              "either :high_entropy_material or :low_entropy_material must be provided, but not both"

      not is_nil(high_entropy_material) ->
        high_entropy_material
        |> to_string()
        |> hkdf_sha256(salt, @default_hkdf_info, 32)
        |> Base.url_encode64()

      not is_nil(low_entropy_material) ->
        iterations =
          Application.get_env(:fastest_mcp, :jwt_kdf_iterations, @default_low_entropy_iterations)

        KeyGenerator.generate(to_string(low_entropy_material), salt,
          iterations: iterations,
          length: 32,
          digest: :sha256,
          cache: Plug.Crypto.Keys
        )
        |> Base.url_encode64()

      true ->
        raise ArgumentError,
              "either :high_entropy_material or :low_entropy_material must be provided"
    end
  end

  @doc "Issues an access token."
  def issue_access_token(%__MODULE__{} = issuer, opts) when is_list(opts) do
    payload =
      base_payload(issuer, opts)
      |> maybe_put_upstream_claims(opts)

    sign(payload, issuer.signing_key)
  end

  @doc "Issues a refresh token."
  def issue_refresh_token(%__MODULE__{} = issuer, opts) when is_list(opts) do
    payload =
      issuer
      |> base_payload(opts)
      |> Map.put("token_use", "refresh")
      |> maybe_put_upstream_claims(opts)

    sign(payload, issuer.signing_key)
  end

  @doc "Verifies the given token."
  def verify_token(%__MODULE__{} = issuer, token, opts \\ []) when is_binary(token) do
    expected_token_use = Keyword.get(opts, :expected_token_use, "access") |> to_string()
    jwk = JOSE.JWK.from_oct(issuer.signing_key)

    case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        claims = normalize_claims(claims)
        validate_claims!(claims, issuer, expected_token_use)
        claims

      _ ->
        raise VerificationError, "invalid token signature"
    end
  rescue
    error in VerificationError ->
      reraise error, __STACKTRACE__

    _error ->
      raise VerificationError, "invalid token"
  end

  defp base_payload(%__MODULE__{} = issuer, opts) do
    now = System.os_time(:second)

    %{
      "iss" => issuer.issuer,
      "aud" => issuer.audience,
      "client_id" => Keyword.fetch!(opts, :client_id) |> to_string(),
      "scope" => opts |> Keyword.get(:scopes, []) |> normalize_scopes() |> Enum.join(" "),
      "exp" => now + Keyword.get(opts, :expires_in, 3600),
      "iat" => now,
      "jti" => Keyword.fetch!(opts, :jti) |> to_string()
    }
  end

  defp maybe_put_upstream_claims(payload, opts) do
    case Keyword.get(opts, :upstream_claims) do
      claims when is_map(claims) and map_size(claims) > 0 ->
        Map.put(payload, "upstream_claims", claims)

      _ ->
        payload
    end
  end

  defp sign(payload, signing_key) do
    {_jws, token} =
      JOSE.JWT.sign(JOSE.JWK.from_oct(signing_key), %{"alg" => "HS256", "typ" => "JWT"}, payload)
      |> JOSE.JWS.compact()

    token
  end

  defp validate_claims!(claims, %__MODULE__{} = issuer, expected_token_use) do
    token_use = Map.get(claims, "token_use", "access")

    if token_use != expected_token_use do
      raise VerificationError,
            "Token type mismatch: expected #{expected_token_use}, got #{token_use}"
    end

    exp = Map.get(claims, "exp")

    if is_integer(exp) and exp < System.os_time(:second) do
      raise VerificationError, "Token has expired"
    end

    if Map.get(claims, "iss") != issuer.issuer do
      raise VerificationError, "Invalid token issuer"
    end

    if Map.get(claims, "aud") != issuer.audience do
      raise VerificationError, "Invalid token audience"
    end

    :ok
  end

  defp normalize_signing_key({:ok, key}), do: normalize_signing_key(key)
  defp normalize_signing_key(key) when is_binary(key), do: key

  defp normalize_claims(claims) do
    Map.new(claims, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: Enum.map(scopes, &to_string/1)
  defp normalize_scopes(nil), do: []
  defp normalize_scopes(scope), do: [to_string(scope)]

  defp hkdf_sha256(ikm, salt, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    block = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(block, 0, length)
  end
end
