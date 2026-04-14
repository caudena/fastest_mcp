defmodule FastestMCP.Auth.JWKSCache do
  @moduledoc """
  Shared cache for JWKS documents fetched during JWT verification.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  @table :fastest_mcp_jwks_cache

  @doc "Fetches the latest state managed by this module."
  def fetch(uri, ttl_ms, fetcher) when is_binary(uri) and is_function(fetcher, 0) do
    ensure_table!()

    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, uri) do
      [{^uri, expires_at, keys}] when expires_at > now ->
        {:ok, keys}

      _ ->
        with {:ok, keys} <- fetcher.() do
          :ets.insert(@table, {uri, now + ttl_ms, keys})
          {:ok, keys}
        end
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end
end
