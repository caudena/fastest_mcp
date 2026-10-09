defmodule FastestMCP.Client.OAuth.URL do
  @moduledoc false
  # URL rules of the OAuth client. Authorization-server URLs are HTTPS-only;
  # the MCP resource, the redirect URI and the resource's own metadata may
  # also use loopback HTTP. Canonical forms lowercase the scheme and host and
  # drop a default port; `exact_https/1` and `preserved_https/1` validate a
  # URL but return it as given.

  alias FastestMCP.URIPolicy

  # The RFC 8707 resource indicator: no query, and no path for an origin.
  def resource(url) do
    with {:ok, uri} <- parse(url, :loopback) do
      cond do
        uri.query -> {:error, :resource_query_forbidden}
        uri.path in [nil, "/"] -> {:ok, URI.to_string(%{uri | path: nil})}
        true -> {:ok, URI.to_string(uri)}
      end
    end
  end

  # An authorization-server metadata document URL.
  def https(url), do: with({:ok, uri} <- parse(url, :https), do: {:ok, canonical(uri)})

  # A protected-resource metadata document URL: HTTPS, or loopback HTTP on
  # the resource's own origin.
  def resource_metadata(url, resource) do
    with {:ok, uri} <- parse(url, :loopback) do
      if uri.scheme == "https" or origin(uri) == origin(URI.parse(resource)),
        do: {:ok, canonical(uri)},
        else: {:error, :https_required}
    end
  end

  # An HTTPS endpoint, returned as given.
  def preserved_https(url), do: with({:ok, _uri} <- parse(url, :https), do: {:ok, url})

  # An HTTPS identifier without a query (an issuer), returned as given.
  def exact_https(url) do
    with {:ok, uri} <- parse(url, :https) do
      if uri.query, do: {:error, :issuer_query_forbidden}, else: {:ok, url}
    end
  end

  # An HTTPS Client ID Metadata Document URL with a path.
  def client_id_document(url) do
    with {:ok, url} <- preserved_https(url) do
      if URI.parse(url).path in [nil, "/"],
        do: {:error, :client_metadata_path_required},
        else: {:ok, url}
    end
  end

  def redirect_uri(url) when is_binary(url) do
    case parse(url, :loopback) do
      {:ok, uri} -> {:ok, canonical(uri)}
      {:error, :https_or_loopback_required} -> {:error, :secure_redirect_uri_required}
      {:error, _reason} -> {:error, :invalid_redirect_uri}
    end
  end

  def redirect_uri(_url), do: {:error, :redirect_uri_required}

  # Whether the redirect a host observed reached the configured endpoint.
  def same_redirect(expected, actual) do
    with {:ok, endpoint} <- endpoint(expected),
         {:ok, ^endpoint} <- endpoint(actual),
         %URI{fragment: nil} <- URI.parse(actual) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :state_or_redirect_mismatch}
    end
  end

  # Metadata for the root of the requested resource's origin covers it.
  def covers?(resource, requested) do
    uri = URI.parse(resource)

    resource == requested or
      (uri.path in [nil, "/"] and origin(uri) == origin(URI.parse(requested)))
  end

  # RFC 9728: path insertion, then the origin root.
  def resource_metadata_urls(resource) do
    uri = URI.parse(resource)

    Enum.uniq([
      well_known(uri, "oauth-protected-resource", uri.path || "/"),
      well_known(uri, "oauth-protected-resource", "")
    ])
  end

  # RFC 8414, then OpenID Connect path insertion and path appending.
  def server_metadata_urls(issuer) do
    uri = URI.parse(issuer)

    case String.trim_trailing(uri.path || "", "/") do
      "" ->
        [
          well_known(uri, "oauth-authorization-server", ""),
          well_known(uri, "openid-configuration", "")
        ]

      path ->
        [
          well_known(uri, "oauth-authorization-server", path),
          well_known(uri, "openid-configuration", path),
          URI.to_string(%{uri | path: path <> "/.well-known/openid-configuration"})
        ]
    end
  end

  defp parse(url, policy) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.host in [nil, ""] ->
        {:error, :host_required}

      uri.userinfo || uri.fragment ->
        {:error, :unsafe_url}

      uri.scheme == "https" or loopback?(uri, policy) ->
        {:ok, %{uri | host: String.downcase(uri.host)}}

      policy == :https ->
        {:error, :https_required}

      true ->
        {:error, :https_or_loopback_required}
    end
  end

  defp parse(_url, _policy), do: {:error, :invalid_url}

  defp loopback?(uri, policy),
    do: policy == :loopback and uri.scheme == "http" and URIPolicy.loopback_host?(uri.host)

  # URI.to_string/1 already omits a default port.
  defp canonical(uri), do: URI.to_string(%{uri | path: uri.path || "/"})

  defp origin(uri), do: {uri.scheme, String.downcase(uri.host), uri.port}

  defp well_known(uri, name, suffix),
    do: URI.to_string(%{uri | path: "/.well-known/" <> name <> suffix})

  defp endpoint(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        {:ok, {scheme, String.downcase(host), uri.port, uri.path || ""}}

      _other ->
        {:error, :invalid_redirect_uri}
    end
  end

  defp endpoint(_url), do: {:error, :invalid_redirect_uri}
end
