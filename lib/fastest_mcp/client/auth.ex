defmodule FastestMCP.Client.Auth do
  @moduledoc false
  # Client credentials as one auth input with string keys at its top level
  # ("authorization", "headers", and the keys of `auth_input:`), merged from
  # the connection's input and per-request options. A configured OAuth client
  # owns the HTTP authorization header. An in-process server receives the
  # auth input as it is, Elixir terms included.

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Client.OAuth

  @options [:auth_input, :authorization, :access_token, :headers]

  def options(opts), do: Keyword.take(opts, @options)

  def normalize(opts) do
    opts = options(opts)
    auth_input = opts |> Keyword.get(:auth_input, %{}) |> normalize_input()

    headers =
      Map.merge(
        Map.get(auth_input, "headers", %{}),
        normalize_headers(Keyword.get(opts, :headers, []))
      )

    authorization =
      opts[:authorization] || bearer(opts[:access_token]) || auth_input["authorization"] ||
        headers["authorization"]

    auth_input
    |> Map.delete("headers")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", headers |> put_header(authorization) |> non_empty())
  end

  # The request's options override the connection's auth input.
  def input(state, opts) do
    base = state.auth_input
    override = normalize(opts)
    headers = Map.merge(Map.get(base, "headers", %{}), Map.get(override, "headers", %{}))

    authorization =
      cond do
        Map.has_key?(override, "authorization") -> override["authorization"]
        Map.has_key?(headers, "authorization") -> headers["authorization"]
        true -> base["authorization"]
      end

    headers =
      if present?(authorization),
        do: Map.put(headers, "authorization", authorization),
        else: Map.delete(headers, "authorization")

    base
    |> Map.merge(Map.delete(override, "headers"))
    |> Map.delete("authorization")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty(headers))
  end

  # A stdio server with `legacy_stdio_auth_metadata: true` reads credentials
  # from request metadata.
  def put_metadata(params, auth_input, enabled?)
      when not enabled? or map_size(auth_input) == 0,
      do: params

  def put_metadata(params, auth_input, true) do
    meta = Map.get(params, "_meta", %{})
    fastestmcp = meta |> Map.get("fastestmcp", %{}) |> Map.put("auth", auth_input)
    Map.put(params, "_meta", Map.put(meta, "fastestmcp", fastestmcp))
  end

  # HTTP credential headers of one request, waiting up to `timeout` for a
  # refreshed or pending OAuth token.
  def headers(state, opts, timeout) do
    headers = state |> input(opts) |> Map.get("headers", %{})

    case state.oauth do
      %{pid: pid, resource: resource} ->
        case OAuth.authorization_header(pid, resource, timeout) do
          {:ok, authorization} -> Map.put(headers, "authorization", authorization)
          _none_or_error -> Map.delete(headers, "authorization")
        end

      nil ->
        headers
    end
  end

  defp bearer(token) when token in [nil, ""], do: nil
  defp bearer(token) when is_binary(token), do: "Bearer " <> token

  defp normalize_input(%{} = auth_input) do
    auth_input = Map.new(auth_input, fn {key, value} -> {to_string(key), value} end)

    case Map.get(auth_input, "headers") do
      nil -> auth_input
      headers -> Map.put(auth_input, "headers", normalize_headers(headers))
    end
  end

  defp normalize_input(auth_input) when is_list(auth_input),
    do: auth_input |> Map.new() |> normalize_input()

  defp normalize_input(_other), do: %{}

  defp normalize_headers(nil), do: %{}

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp put_header(headers, authorization) do
    if present?(authorization),
      do: Map.put(headers, "authorization", authorization),
      else: headers
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp non_empty(map) when map_size(map) == 0, do: nil
  defp non_empty(map), do: map
end
