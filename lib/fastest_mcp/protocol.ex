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

  @server_method_capabilities %{
    "tools/list" => ["tools"],
    "tools/call" => ["tools"],
    "resources/list" => ["resources"],
    "resources/templates/list" => ["resources"],
    "resources/read" => ["resources"],
    "resources/subscribe" => ["resources", "subscribe"],
    "resources/unsubscribe" => ["resources", "subscribe"],
    "prompts/list" => ["prompts"],
    "prompts/get" => ["prompts"],
    "completion/complete" => ["completions"],
    "logging/setLevel" => ["logging"],
    "tasks/list" => ["tasks", "list"],
    "tasks/cancel" => ["tasks", "cancel"]
  }

  @client_method_capabilities %{
    "roots/list" => ["roots"],
    "sampling/createMessage" => ["sampling"],
    "tasks/list" => ["tasks", "list"],
    "tasks/cancel" => ["tasks", "cancel"]
  }

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

  @doc "Returns whether the given capability path is advertised and enabled."
  def capability?(capabilities, path) do
    case capability(capabilities, path) do
      nil -> false
      false -> false
      _advertised -> true
    end
  end

  @doc "Returns whether the capability path contains an advertised capability object."
  def capability_object?(capabilities, path),
    do: is_map(capability(capabilities, path))

  @doc "Returns whether the capability path is the boolean value true."
  def capability_flag?(capabilities, path),
    do: capability(capabilities, path) == true

  @doc false
  def required_server_capability(method) when is_binary(method),
    do: Map.get(@server_method_capabilities, method)

  @doc false
  def server_supports_method?(capabilities, method) when is_binary(method) do
    case required_server_capability(method) do
      nil -> true
      path -> capability?(capabilities, path)
    end
  end

  @doc false
  def required_client_capability("elicitation/create", params) when is_map(params) do
    case Map.get(params, "mode", "form") do
      "url" -> ["elicitation", "url"]
      _form -> ["elicitation", "form"]
    end
  end

  def required_client_capability(method, _params) when is_binary(method),
    do: Map.get(@client_method_capabilities, method)

  @doc false
  def client_supports_method?(capabilities, method, params \\ %{}) do
    case required_client_capability(method, params) do
      nil -> true
      path -> capability?(capabilities, path)
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end
end
