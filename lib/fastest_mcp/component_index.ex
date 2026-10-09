defmodule FastestMCP.ComponentIndex do
  @moduledoc false
  # Static components of a running server, keyed by `{type, identifier,
  # version}` for exact lookups. The calling runtime process owns the table and
  # registers it, so it disappears with that process.

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.Registry

  def create(server_name, components) do
    table = :ets.new(__MODULE__, [:ordered_set, :protected, read_concurrency: true])
    :ets.insert(table, Enum.map(components, &{key(&1), &1}))
    :ok = Registry.register_component_index(server_name, table)
    table
  end

  # In key order.
  def list(server_name, type), do: select(server_name, {{type, :_, :_}, :_})

  # Exact matches, highest version first.
  def candidates(server_name, type, identifier, version \\ nil) do
    version = if version, do: Lookup.version_key(version), else: :_

    server_name
    |> select({{type, to_string(identifier), version}, :_})
    |> Lookup.sort_by_version_desc()
  end

  defp key(component),
    do:
      {Component.kind(component), Component.identifier(component),
       Lookup.version_key(component.version)}

  defp select(server_name, pattern) do
    case Registry.component_index(server_name) do
      {:ok, table} -> table |> :ets.match_object(pattern) |> Enum.map(&elem(&1, 1))
      {:error, :not_found} -> []
    end
  rescue
    # The owning runtime stopped between the registry lookup and the read.
    ArgumentError -> []
  end
end
