defmodule FastestMCP.Protocol do
  @moduledoc """
  Central protocol version and capability helpers.
  Keep the active MCP protocol baseline in one place so server responses, client
  handshakes, and tests do not drift.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  @current_version "2025-11-25"

  @doc "Returns the active MCP protocol version supported by the library."
  def current_version, do: @current_version

  @doc "Returns the protocol version string for the given input."
  def version(metadata_or_server, default \\ @current_version)

  def version(%{metadata: metadata}, default) when is_map(metadata) do
    version(metadata, default)
  end

  def version(metadata, default) when is_map(metadata) do
    metadata_value(metadata, :protocol_version) ||
      metadata_value(metadata, :protocolVersion) ||
      default
  end

  def version(_other, default), do: default

  @doc "Normalizes capability input into a stable map."
  def normalize_capabilities(nil), do: %{}

  def normalize_capabilities(capabilities) when is_map(capabilities) do
    capabilities
    |> Map.new(fn {key, value} ->
      normalized_value =
        if is_map(value) do
          normalize_capabilities(value)
        else
          value
        end

      {to_string(key), normalized_value}
    end)
  end

  @doc "Reads one capability value from a capability map."
  def capability(capabilities, path, default \\ nil)

  def capability(capabilities, path, default) when is_list(path) do
    Enum.reduce_while(path, normalize_capabilities(capabilities), fn segment, current ->
      key = to_string(segment)

      case current do
        %{} = map ->
          case Map.fetch(map, key) do
            {:ok, value} -> {:cont, value}
            :error -> {:halt, default}
          end

        _other ->
          {:halt, default}
      end
    end)
  end

  @doc "Returns whether the given capability flag is enabled."
  def capability?(capabilities, path) do
    not is_nil(capability(capabilities, path))
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end
end
