defmodule FastestMCP.Auth.Introspection do
  @moduledoc """
  OAuth 2.0 token introspection verifier (RFC 7662).

  It validates opaque bearer tokens by POSTing them to an introspection
  endpoint and mapping the response into the shared FastestMCP auth contract.

  Required options:

  - `:introspection_url`
  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:client_auth_method` - `"client_secret_basic"` (default) or
    `"client_secret_post"`
  - `:required_scopes` - scopes enforced on active tokens
  - `:timeout_ms` - introspection request timeout, defaults to `5_000`
  - `:http_client` / `:http_requester` - custom requester used for network calls
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.Result
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.Error
  alias FastestMCP.HTTP

  @client_auth_methods ["client_secret_basic", "client_secret_post"]

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, _context, opts) do
    with {:ok, token} <- fetch_token(input),
         {:ok, auth_method} <- validate_client_auth_method(opts),
         {:ok, payload} <- introspect(token, auth_method, opts),
         :ok <- validate_active(payload),
         :ok <- validate_expiration(payload),
         scopes = scopes_from_claims(payload),
         :ok <- validate_required_scopes(scopes, opts) do
      {:ok,
       %Result{
         principal: payload,
         auth: %{
           provider: :introspection,
           subject: payload["sub"],
           client_id: client_identifier(payload),
           scopes: scopes
         },
         capabilities: scopes
       }}
    end
  end

  defp introspect(token, "client_secret_basic", opts) do
    headers = [
      {"authorization", "Basic " <> basic_credentials(opts)}
    ]

    do_introspect(token, headers, %{}, opts)
  end

  defp introspect(token, "client_secret_post", opts) do
    form = %{
      "client_id" => opt(opts, :client_id),
      "client_secret" => opt(opts, :client_secret)
    }

    do_introspect(token, [], form, opts)
  end

  defp do_introspect(token, headers, extra_form, opts) do
    form =
      %{
        "token" => token,
        "token_type_hint" => "access_token"
      }
      |> Map.merge(extra_form)

    case fetch_introspection(form, headers, opts) do
      {:ok, 200, _headers, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _status, _headers, _payload} ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

      {:error, _reason} ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
    end
  end

  defp fetch_introspection(form, headers, opts) do
    timeout_ms = opt(opts, :timeout_ms, 5_000)

    if opt(opts, :ssrf_safe, true) do
      SSRF.post_form_json(opt(opts, :introspection_url), form,
        headers: headers,
        timeout_ms: timeout_ms,
        overall_timeout_ms: opt(opts, :ssrf_overall_timeout_ms, 30_000),
        max_size_bytes: opt(opts, :ssrf_max_size_bytes, 5_120),
        resolver: opt(opts, :ssrf_resolver),
        requester: opt(opts, :ssrf_requester) || http_requester(opts)
      )
    else
      HTTP.post_form_json(opt(opts, :introspection_url), form,
        headers: headers,
        timeout_ms: timeout_ms,
        requester: http_requester(opts)
      )
    end
  end

  defp http_requester(opts) do
    opt(opts, :http_requester) || opt(opts, :http_client)
  end

  defp validate_client_auth_method(opts) do
    auth_method = opt(opts, :client_auth_method, "client_secret_basic")

    if auth_method in @client_auth_methods do
      {:ok, auth_method}
    else
      {:error,
       %Error{
         code: :internal_error,
         message: "invalid client_auth_method",
         details: %{client_auth_method: inspect(auth_method), allowed: @client_auth_methods}
       }}
    end
  end

  defp validate_active(%{"active" => true}), do: :ok

  defp validate_active(_payload),
    do: {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second) do
      :ok
    else
      {:error, %Error{code: :unauthorized, message: "token expired"}}
    end
  end

  defp validate_expiration(_payload), do: :ok

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

  defp scopes_from_claims(%{"scope" => scopes}) when is_binary(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  defp scopes_from_claims(%{"scope" => scopes}) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp scopes_from_claims(_claims), do: []

  defp client_identifier(payload) do
    payload["client_id"] || payload["sub"] || "unknown"
  end

  defp basic_credentials(opts) do
    "#{opt(opts, :client_id)}:#{opt(opts, :client_secret)}"
    |> Base.encode64()
  end

  defp fetch_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token(%{"authorization" => "Bearer " <> token}), do: {:ok, token}
  defp fetch_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: {:ok, token}

  defp fetch_token(_input),
    do: {:error, %Error{code: :unauthorized, message: "missing credentials"}}

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
