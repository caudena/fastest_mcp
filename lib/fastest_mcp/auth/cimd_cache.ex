defmodule FastestMCP.Auth.CIMDCache do
  @moduledoc """
  In-memory cache for fetched client-id metadata documents.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  @table :fastest_mcp_cimd_cache

  @doc "Reads a value from the backing store."
  def get(uri) when is_binary(uri) do
    ensure_table!()

    case :ets.lookup(@table, uri) do
      [{^uri, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Stores a value in the backing store."
  def put(uri, entry) when is_binary(uri) and is_map(entry) do
    ensure_table!()
    :ets.insert(@table, {uri, entry})
    :ok
  end

  @doc "Deletes a value from the backing store."
  def delete(uri) when is_binary(uri) do
    ensure_table!()
    :ets.delete(@table, uri)
    :ok
  end

  @doc "Clears all cached entries."
  def clear do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
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
