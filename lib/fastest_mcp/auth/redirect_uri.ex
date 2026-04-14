defmodule FastestMCP.Auth.RedirectURI do
  @moduledoc """
  Helpers for validating redirect URIs against configured rules.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  @doc "Validates the given redirect URI against the configured rules."
  def validate_redirect_uri(nil, _allowed_patterns), do: true
  def validate_redirect_uri(redirect_uri, nil) when is_binary(redirect_uri), do: true

  def validate_redirect_uri(redirect_uri, allowed_patterns)
      when is_binary(redirect_uri) and is_list(allowed_patterns) do
    Enum.any?(allowed_patterns, &matches_allowed_pattern?(redirect_uri, &1))
  end

  def validate_redirect_uri(_redirect_uri, _allowed_patterns), do: false

  @doc "Checks whether the redirect URI matches one allowed pattern."
  def matches_allowed_pattern?(redirect_uri, pattern)
      when is_binary(redirect_uri) and is_binary(pattern) do
    with {:ok, uri} <- parse_uri(redirect_uri),
         {:ok, parsed_pattern} <- parse_uri(pattern),
         {uri_host, uri_port} <- parse_host_port(uri.authority),
         {pattern_host, pattern_port} <- parse_host_port(parsed_pattern.authority),
         true <- uri_scheme_matches?(uri, parsed_pattern),
         true <- match_host?(uri_host, pattern_host),
         true <- match_port?(uri, uri_port, pattern_host, pattern_port),
         true <- match_path?(uri.path, parsed_pattern.path) do
      true
    else
      _ -> false
    end
  end

  def matches_allowed_pattern?(_redirect_uri, _pattern), do: false

  @doc "Returns whether the pattern contains wildcards."
  def wildcard_pattern?(pattern) when is_binary(pattern), do: String.contains?(pattern, "*")
  def wildcard_pattern?(_pattern), do: false

  @doc "Returns whether the URI is a loopback redirect URI without an explicit port."
  def loopback_without_port?(redirect_uri) when is_binary(redirect_uri) do
    with {:ok, uri} <- parse_uri(redirect_uri),
         {host, port} <- parse_host_port(uri.authority) do
      loopback_host?(host) and is_nil(port)
    else
      _ -> false
    end
  end

  def loopback_without_port?(_redirect_uri), do: false

  defp parse_uri(value) do
    uri = URI.parse(value)

    cond do
      is_nil(uri.scheme) or uri.scheme == "" ->
        {:error, :missing_scheme}

      is_nil(uri.authority) or uri.authority == "" ->
        {:error, :missing_authority}

      not is_nil(uri.userinfo) ->
        {:error, :userinfo_not_allowed}

      true ->
        {:ok, uri}
    end
  end

  defp uri_scheme_matches?(uri, pattern) do
    String.downcase(uri.scheme || "") == String.downcase(pattern.scheme || "")
  end

  defp parse_host_port(nil), do: {nil, nil}

  defp parse_host_port(authority) when is_binary(authority) do
    authority =
      case String.split(authority, "@", parts: 2) do
        [_userinfo, host_port] -> host_port
        [host_port] -> host_port
      end

    cond do
      String.starts_with?(authority, "[") ->
        parse_ipv6_host_port(authority)

      String.contains?(authority, ":") ->
        case String.split(authority, ":", parts: 2) do
          [host, port] -> {host, port}
          [host] -> {host, nil}
        end

      true ->
        {authority, nil}
    end
  end

  defp parse_ipv6_host_port(authority) do
    case String.split(authority, "]", parts: 2) do
      [<<"[", host::binary>>, ":" <> port] -> {host, port}
      [<<"[", host::binary>>, ""] -> {host, nil}
      [<<"[", host::binary>>] -> {host, nil}
      _ -> {authority, nil}
    end
  end

  defp match_host?(uri_host, pattern_host) do
    uri_host = normalize_host(uri_host)
    pattern_host = normalize_host(pattern_host)

    cond do
      is_nil(uri_host) or is_nil(pattern_host) ->
        uri_host == pattern_host

      String.starts_with?(pattern_host, "*.") ->
        suffix = String.trim_leading(pattern_host, "*")
        base_host = String.trim_leading(suffix, ".")
        String.ends_with?(uri_host, suffix) and uri_host != base_host

      true ->
        uri_host == pattern_host
    end
  end

  defp match_port?(uri, uri_port, pattern_host, pattern_port) do
    cond do
      pattern_port == "*" ->
        true

      loopback_host?(pattern_host) and is_nil(pattern_port) ->
        true

      true ->
        effective_port(uri_port, uri.scheme) == effective_port(pattern_port, uri.scheme)
    end
  end

  defp match_path?(uri_path, pattern_path) do
    uri_path = normalize_path(uri_path)
    pattern_path = normalize_path(pattern_path)

    if pattern_path == "/" do
      true
    else
      regex =
        pattern_path
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> then(&Regex.compile!("^" <> &1 <> "$"))

      Regex.match?(regex, uri_path)
    end
  end

  defp normalize_host(nil), do: nil
  defp normalize_host(host), do: String.downcase(host)

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path

  defp effective_port(nil, "https"), do: "443"
  defp effective_port(nil, _scheme), do: "80"
  defp effective_port(port, _scheme), do: to_string(port)

  defp loopback_host?(host) when is_binary(host) do
    String.downcase(host) in ["localhost", "127.0.0.1", "::1"]
  end

  defp loopback_host?(_host), do: false
end
