defmodule FastestMCP.Auth.CIMD do
  @moduledoc """
  Helpers for Client ID Metadata Documents and redirect-uri validation.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  alias FastestMCP.Auth.CIMDCache
  alias FastestMCP.Auth.RedirectURI
  alias FastestMCP.Auth.SSRF

  @supported_token_auth_methods ["none", "private_key_jwt"]
  @default_cache_ttl_ms 60 * 60_000

  @doc "Returns whether the value looks like a client-id URL."
  def is_client_id?(client_id) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path}
      when is_binary(host) and host != "" and path not in [nil, "", "/"] ->
        true

      _ ->
        false
    end
  end

  def is_client_id?(_client_id), do: false

  @doc "Fetches the latest state managed by this module."
  def fetch(client_id_url, opts \\ []) when is_binary(client_id_url) do
    now_ms = now_ms(opts)

    case CIMDCache.get(client_id_url) do
      {:ok, cached} ->
        fetch_with_cache(client_id_url, cached, now_ms, opts)

      {:error, :not_found} ->
        fetch_uncached(client_id_url, now_ms, opts)
    end
  end

  @doc "Validates the given redirect URI against the configured rules."
  def validate_redirect_uri(document, redirect_uri) when is_binary(redirect_uri) do
    redirect_uri = to_string(redirect_uri)

    if Enum.any?(document["redirect_uris"], &redirect_uri_matches?(&1, redirect_uri)) do
      {:ok, redirect_uri}
    else
      {:error, :invalid_redirect_uri}
    end
  end

  def validate_redirect_uri(_document, _redirect_uri), do: {:error, :missing_redirect_uri}

  @doc "Returns the default redirect URI derived from the document."
  def default_redirect_uri(document) do
    case Enum.filter(document["redirect_uris"], &exact_default_redirect_uri?/1) do
      [redirect_uri] -> {:ok, redirect_uri}
      _ -> {:error, :redirect_uri_required}
    end
  end

  defp fetch_with_cache(client_id_url, cached, now_ms, opts) do
    cond do
      not cached.must_revalidate and now_ms < cached.expires_at_ms ->
        {:ok, cached.document}

      true ->
        conditional_headers = conditional_headers(cached)

        with {:ok, status, headers, payload} <-
               fetch_payload(client_id_url, conditional_headers, opts) do
          case status do
            200 -> handle_fresh_response(client_id_url, payload, headers, now_ms, opts)
            304 -> handle_not_modified(client_id_url, cached, headers, now_ms, opts)
            other -> {:error, "unexpected CIMD response status: #{other}"}
          end
        end
    end
  end

  defp fetch_uncached(client_id_url, now_ms, opts) do
    with {:ok, 200, headers, payload} <- fetch_payload(client_id_url, [], opts) do
      handle_fresh_response(client_id_url, payload, headers, now_ms, opts)
    else
      {:ok, status, _headers, _payload} ->
        {:error, "unexpected CIMD response status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_payload(client_id_url, request_headers, opts) do
    case Keyword.get(opts, :cimd_fetcher) do
      custom when is_function(custom, 2) ->
        normalize_fetch_response(custom.(client_id_url, request_headers))

      custom when is_function(custom, 1) ->
        normalize_fetch_response(custom.(client_id_url))

      nil ->
        with {:ok, status, headers, body} <-
               SSRF.request(:get, client_id_url,
                 headers: request_headers,
                 require_path: true,
                 timeout_ms: Keyword.get(opts, :cimd_timeout_ms, 5_000),
                 overall_timeout_ms: Keyword.get(opts, :cimd_overall_timeout_ms, 30_000),
                 max_size_bytes: Keyword.get(opts, :cimd_max_size_bytes, 5_120),
                 resolver: Keyword.get(opts, :cimd_resolver),
                 requester: Keyword.get(opts, :cimd_requester)
               ),
             {:ok, payload} <- decode_cimd_payload(status, body) do
          {:ok, status, headers, payload}
        end
    end
  end

  defp handle_fresh_response(client_id_url, payload, headers, now_ms, opts) do
    with {:ok, document} <- validate_document(payload, client_id_url, opts) do
      policy = parse_cache_policy(headers, now_ms, opts)

      if policy.no_store do
        :ok = CIMDCache.delete(client_id_url)
      else
        :ok =
          CIMDCache.put(client_id_url, %{
            document: document,
            etag: policy.etag,
            last_modified: policy.last_modified,
            expires_at_ms: policy.expires_at_ms,
            freshness_lifetime_ms: policy.freshness_lifetime_ms,
            must_revalidate: policy.must_revalidate
          })
      end

      {:ok, document}
    end
  end

  defp handle_not_modified(client_id_url, cached, headers, now_ms, opts) do
    policy =
      if has_freshness_headers?(headers) do
        parse_cache_policy(headers, now_ms, opts)
      else
        %{
          etag: nil,
          last_modified: nil,
          expires_at_ms: now_ms + cached.freshness_lifetime_ms,
          freshness_lifetime_ms: cached.freshness_lifetime_ms,
          must_revalidate: cached.must_revalidate,
          no_store: false
        }
      end

    if policy.no_store do
      :ok = CIMDCache.delete(client_id_url)
    else
      :ok =
        CIMDCache.put(client_id_url, %{
          document: cached.document,
          etag: policy.etag || cached.etag,
          last_modified: policy.last_modified || cached.last_modified,
          expires_at_ms: policy.expires_at_ms,
          freshness_lifetime_ms: policy.freshness_lifetime_ms,
          must_revalidate: policy.must_revalidate
        })
    end

    {:ok, cached.document}
  end

  defp normalize_fetch_response({:ok, status, headers, payload})
       when is_integer(status) and is_list(headers) do
    {:ok, status, headers, payload}
  end

  defp normalize_fetch_response({:ok, payload, headers}) when is_list(headers) do
    {:ok, 200, headers, payload}
  end

  defp normalize_fetch_response({:ok, payload}), do: {:ok, 200, [], payload}
  defp normalize_fetch_response({:error, reason}), do: {:error, reason}

  defp decode_cimd_payload(304, _body), do: {:ok, nil}
  defp decode_cimd_payload(_status, body), do: Jason.decode(body)

  defp conditional_headers(cached) do
    []
    |> maybe_put_header("if-none-match", cached.etag)
    |> maybe_put_header("if-modified-since", cached.last_modified)
  end

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: headers ++ [{key, value}]

  defp parse_cache_policy(headers, now_ms, opts) do
    headers = normalize_headers(headers)

    directives =
      headers
      |> Map.get("cache-control", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    no_store = "no-store" in directives
    must_revalidate = "no-cache" in directives

    max_age_ms =
      Enum.find_value(directives, fn
        <<"max-age=", value::binary>> ->
          case Integer.parse(String.trim(value)) do
            {seconds, ""} when seconds >= 0 -> seconds * 1_000
            _ -> nil
          end

        _other ->
          nil
      end)

    expires_at_ms =
      cond do
        is_integer(max_age_ms) ->
          now_ms + max_age_ms

        expires = headers["expires"] ->
          parse_http_datetime_ms(expires) || now_ms + default_cache_ttl_ms(opts)

        true ->
          now_ms + default_cache_ttl_ms(opts)
      end

    %{
      etag: headers["etag"],
      last_modified: headers["last-modified"],
      expires_at_ms: expires_at_ms,
      freshness_lifetime_ms: max(expires_at_ms - now_ms, 0),
      no_store: no_store,
      must_revalidate: must_revalidate
    }
  end

  defp validate_document(payload, client_id_url, opts) when is_map(payload) do
    client_id = fetch_field(payload, :client_id)
    redirect_uris = fetch_field(payload, :redirect_uris)
    token_endpoint_auth_method = fetch_field(payload, :token_endpoint_auth_method, "none")

    cond do
      client_id != client_id_url ->
        {:error, "client_id mismatch"}

      not is_list(redirect_uris) or redirect_uris == [] ->
        {:error, "redirect_uris must be a non-empty list"}

      token_endpoint_auth_method not in @supported_token_auth_methods ->
        {:error, "token_endpoint_auth_method is unsupported"}

      true ->
        with {:ok, normalized_redirect_uris} <- validate_redirect_uris(redirect_uris),
             :ok <- validate_jwks_uri(fetch_field(payload, :jwks_uri), opts) do
          {:ok,
           %{
             "client_id" => client_id_url,
             "client_name" => fetch_field(payload, :client_name),
             "redirect_uris" => normalized_redirect_uris,
             "token_endpoint_auth_method" => token_endpoint_auth_method,
             "grant_types" =>
               List.wrap(fetch_field(payload, :grant_types, ["authorization_code"])),
             "response_types" => List.wrap(fetch_field(payload, :response_types, ["code"])),
             "scope" => fetch_field(payload, :scope),
             "jwks_uri" => fetch_field(payload, :jwks_uri),
             "jwks" => fetch_field(payload, :jwks)
           }}
        end
    end
  end

  defp validate_document(_payload, _client_id_url, _opts),
    do: {:error, "client metadata must be an object"}

  defp validate_redirect_uris(redirect_uris) do
    redirect_uris
    |> Enum.map(&to_string/1)
    |> Enum.reduce_while({:ok, []}, fn redirect_uri, {:ok, acc} ->
      case String.trim(redirect_uri) do
        "" ->
          {:halt, {:error, "redirect_uris must be non-empty strings"}}

        normalized ->
          case URI.parse(normalized) do
            %URI{scheme: nil} ->
              {:halt, {:error, "redirect_uri must have a scheme"}}

            %URI{scheme: scheme, host: nil} when scheme != "urn" ->
              {:halt, {:error, "redirect_uri must have a host"}}

            _uri ->
              {:cont, {:ok, acc ++ [normalized]}}
          end
      end
    end)
  end

  defp validate_jwks_uri(nil, _opts), do: :ok

  defp validate_jwks_uri(jwks_uri, opts) when is_binary(jwks_uri) do
    case SSRF.validate_url(jwks_uri,
           resolver: Keyword.get(opts, :cimd_resolver)
         ) do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, "jwks_uri failed SSRF validation: #{reason}"}
    end
  end

  defp validate_jwks_uri(_jwks_uri, _opts), do: :ok

  defp redirect_uri_matches?(template, redirect_uri) do
    RedirectURI.matches_allowed_pattern?(redirect_uri, template)
  end

  defp exact_default_redirect_uri?(redirect_uri) do
    not RedirectURI.wildcard_pattern?(redirect_uri) and
      not RedirectURI.loopback_without_port?(redirect_uri)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp has_freshness_headers?(headers) do
    headers = normalize_headers(headers)
    Map.has_key?(headers, "cache-control") or Map.has_key?(headers, "expires")
  end

  defp parse_http_datetime_ms(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :httpd_util.convert_request_date()
    |> case do
      {{year, month, day}, {hour, minute, second}} ->
        gregorian_seconds =
          :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})

        unix_seconds =
          gregorian_seconds - :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

        unix_seconds * 1_000

      :bad_date ->
        nil
    end
  rescue
    _error -> nil
  end

  defp default_cache_ttl_ms(opts),
    do: Keyword.get(opts, :cimd_cache_ttl_ms, @default_cache_ttl_ms)

  defp now_ms(opts) do
    case Keyword.get(opts, :cimd_now_ms) do
      now when is_integer(now) ->
        now

      now when is_function(now, 0) ->
        now.()

      nil ->
        System.system_time(:millisecond)
    end
  end

  defp fetch_field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
