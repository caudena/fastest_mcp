defmodule FastestMCP.TestSupport.ConformanceOAuthBridge do
  @moduledoc false

  alias FastestMCP.Client.OAuth.AuthorizationHandler
  alias FastestMCP.HTTP

  @authorization_server_fields [
    "issuer",
    "authorization_endpoint",
    "token_endpoint",
    "registration_endpoint"
  ]

  # @modelcontextprotocol/conformance 0.1.16 serves its OAuth authorization
  # server on loopback HTTP, despite MCP 2025-11-25 requiring HTTPS for the
  # authorization server and its endpoints. Keep that defect outside runtime
  # code: production OAuth sees logical HTTPS metadata, while this test-only
  # requester maps logical loopback HTTPS back to the runner's physical HTTP.
  # The protected-resource `resource` identifier is intentionally untouched.
  def request(method, logical_url, opts) do
    physical_url = physical_url(logical_url)

    case HTTP.request(method, physical_url, opts) do
      {:ok, status, headers, body} ->
        {headers, body} = rewrite_metadata_response(headers, body)
        {:ok, status, headers, body}

      {:error, _reason} = error ->
        error
    end
  end

  def authorize(%AuthorizationHandler.Request{} = request) do
    physical_authorization_url = physical_url(request.authorization_url)

    case HTTP.request(:get, physical_authorization_url,
           headers: [{"accept", "text/html, application/json"}],
           http_options: [autoredirect: false],
           timeout_ms: 10_000
         ) do
      {:ok, status, headers, _body} when status in 300..399 ->
        case response_header(headers, "location") do
          nil -> {:error, :authorization_redirect_missing}
          location -> {:ok, URI.merge(request.authorization_url, location) |> URI.to_string()}
        end

      {:ok, status, _headers, _body} ->
        {:error, {:authorization_endpoint_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def logical_metadata(document) when is_map(document) do
    document
    |> update_authorization_servers()
    |> update_authorization_server_fields()
  end

  @doc false
  def physical_url(url) when is_binary(url), do: rewrite_loopback_scheme(url, "https", "http")

  defp rewrite_metadata_response(headers, body) do
    with {:ok, document} when is_map(document) <- JSON.decode(body),
         rewritten when rewritten != document <- logical_metadata(document) do
      body = JSON.encode!(rewritten)
      {replace_content_length(headers, byte_size(body)), body}
    else
      _unchanged_or_non_json -> {headers, body}
    end
  end

  defp update_authorization_servers(%{"authorization_servers" => servers} = document)
       when is_list(servers) do
    Map.put(document, "authorization_servers", Enum.map(servers, &logical_url/1))
  end

  defp update_authorization_servers(document), do: document

  defp update_authorization_server_fields(document) do
    Enum.reduce(@authorization_server_fields, document, fn field, acc ->
      case acc[field] do
        value when is_binary(value) -> Map.put(acc, field, logical_url(value))
        _other -> acc
      end
    end)
  end

  defp logical_url(url) when is_binary(url), do: rewrite_loopback_scheme(url, "http", "https")
  defp logical_url(value), do: value

  defp rewrite_loopback_scheme(url, source_scheme, target_scheme) do
    case URI.parse(url) do
      %URI{scheme: ^source_scheme, host: host} = uri when is_binary(host) ->
        if loopback?(host), do: URI.to_string(%{uri | scheme: target_scheme}), else: url

      _other ->
        url
    end
  end

  defp loopback?(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp replace_content_length(headers, length) do
    headers =
      Enum.reject(headers, fn {key, _value} ->
        String.downcase(to_string(key)) == "content-length"
      end)

    [{"content-length", Integer.to_string(length)} | headers]
  end

  defp response_header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end
end
