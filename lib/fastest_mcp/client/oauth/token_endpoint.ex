defmodule FastestMCP.Client.OAuth.TokenEndpoint do
  @moduledoc false
  # HTTP of the OAuth client: one bounded request helper, and the
  # token-endpoint pipeline every grant and refresh shares (client
  # authentication, the POST, and the validated token set).

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Client.OAuth.ClientAssertionProvider
  alias FastestMCP.Client.OAuth.Config
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.HTTP

  @client_assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # Exchanges `params` for a token set at the token endpoint of
  # `flow.server_metadata`, authenticated as `flow.client`. A refresh keeps
  # `refresh_token` unless the server rotates it.
  def exchange(flow, grant_type, params, refresh_token \\ nil) do
    metadata = flow.server_metadata
    form = [{"grant_type", grant_type} | params]

    with {:ok, form, headers} <- authenticate(form, flow.client, metadata, grant_type),
         {:ok, body} <-
           post(flow.config, metadata["token_endpoint"], form: form, headers: headers),
         {:ok, token} <- token_set(body, flow.scopes, refresh_token) do
      {:ok, token}
    else
      {:error, reason} -> {:error, Error.exception(stage: stage(grant_type), reason: reason)}
    end
  end

  # POSTs `opts` (`form:` and `headers:`, or `json:`) and returns a 2xx body.
  def post(config, url, opts) do
    case request(config, :post, url, opts) do
      {:ok, status, _headers, body} when status in 200..299 -> {:ok, body}
      {:ok, status, _headers, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A configured requester receives the request unbounded; its body is
  # checked afterwards.
  def request(config, method, url, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:timeout_ms, config.timeout_ms)
      |> maybe_put(:requester, config.requester)

    result =
      if config.requester,
        do: HTTP.request(method, url, opts),
        else: HTTP.bounded_request(method, url, config.max_body_bytes, opts)

    case result do
      {:ok, _status, _headers, body}
      when is_binary(body) and byte_size(body) > config.max_body_bytes ->
        {:error, :response_too_large}

      result ->
        result
    end
  end

  def json(body) do
    case JSON.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _other} -> {:error, :json_object_required}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # Space-separated or listed scopes; anything else is no scope.
  def scopes(scopes) when is_binary(scopes), do: String.split(scopes, ~r/\s+/, trim: true)
  def scopes(scopes) when is_list(scopes), do: Enum.filter(scopes, &(is_binary(&1) and &1 != ""))
  def scopes(_scopes), do: []

  defp stage("refresh_token"), do: :token_refresh
  defp stage(_grant_type), do: :token_exchange

  defp authenticate(form, %{token_endpoint_auth_method: "none"}, _metadata, _grant_type),
    do: {:ok, form, []}

  defp authenticate(
         form,
         %{token_endpoint_auth_method: "client_secret_basic"} = client,
         _metadata,
         _grant_type
       ) do
    credentials =
      URI.encode_www_form(client.client_id) <> ":" <> URI.encode_www_form(client.client_secret)

    {:ok, form, [{"authorization", "Basic " <> Base.encode64(credentials)}]}
  end

  defp authenticate(
         form,
         %{token_endpoint_auth_method: "client_secret_post"} = client,
         _metadata,
         _grant_type
       ),
       do: {:ok, form ++ [{"client_secret", client.client_secret}], []}

  defp authenticate(
         form,
         %{token_endpoint_auth_method: "private_key_jwt"} = client,
         metadata,
         grant_type
       ) do
    request = %ClientAssertionProvider.Request{
      client_id: client.client_id,
      token_endpoint: metadata["token_endpoint"],
      authorization_server: metadata["issuer"],
      signing_algorithms: scopes(metadata["token_endpoint_auth_signing_alg_values_supported"]),
      grant_type: grant_type
    }

    case Config.invoke(client.assertion_provider, :assertion, request) do
      {:ok, assertion} when is_binary(assertion) and assertion != "" ->
        assertion = [
          {"client_assertion_type", @client_assertion_type},
          {"client_assertion", assertion}
        ]

        {:ok, form ++ assertion, []}

      _other ->
        {:error, :client_assertion_failed}
    end
  catch
    _kind, _reason -> {:error, :client_assertion_failed}
  end

  defp token_set(body, requested_scopes, refresh_token) do
    with {:ok, document} <- json(body),
         access_token when is_binary(access_token) and access_token != "" <-
           document["access_token"],
         token_type when is_binary(token_type) <- document["token_type"],
         true <- String.downcase(token_type) == "bearer",
         {:ok, expires_at_ms} <- expiry(document["expires_in"]) do
      {:ok,
       %{
         "access_token" => access_token,
         "token_type" => "Bearer",
         "refresh_token" => document["refresh_token"] || refresh_token,
         "scope" => scopes(document["scope"] || requested_scopes),
         "expires_at_ms" => expires_at_ms
       }}
    else
      false -> {:error, :invalid_token_type}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_token_response}
    end
  end

  defp expiry(nil), do: {:ok, nil}

  defp expiry(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, System.system_time(:millisecond) + seconds * 1_000}

  defp expiry(_seconds), do: {:error, :invalid_token_expiry}
end
