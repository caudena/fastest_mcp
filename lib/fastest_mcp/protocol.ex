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

  @supported_versions ["2026-07-28", "2025-11-25"]
  @current_version hd(@supported_versions)
  @profiles %{
    "2026-07-28" => :modern,
    "2025-11-25" => :legacy
  }

  @type version :: String.t()
  @type profile :: :modern | :legacy | :unsupported

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
    "tasks/get" => ["tasks"],
    "tasks/update" => ["tasks"],
    "tasks/list" => ["tasks", "list"],
    "tasks/cancel" => ["tasks", "cancel"]
  }

  @client_method_capabilities %{
    "roots/list" => ["roots"],
    "sampling/createMessage" => ["sampling"],
    "tasks/list" => ["tasks", "list"],
    "tasks/cancel" => ["tasks", "cancel"]
  }

  @doc "Returns supported MCP protocol versions in preference order, newest first."
  @spec supported_versions() :: [version()]
  def supported_versions, do: @supported_versions

  @doc "Returns whether the exact protocol version is supported."
  @spec supported_version?(term()) :: boolean()
  def supported_version?(version), do: Map.has_key?(@profiles, version)

  @doc "Returns the preferred MCP protocol version supported by the library."
  @spec current_version() :: version()
  def current_version, do: @current_version

  @doc "Returns the implementation profile for a protocol version."
  @spec profile(term()) :: profile()
  def profile(version), do: Map.get(@profiles, version, :unsupported)

  @doc "Returns the implementation profile for a supported protocol version."
  @spec profile!(term()) :: :modern | :legacy
  def profile!(version) do
    case profile(version) do
      :unsupported ->
        raise ArgumentError,
              "unsupported MCP protocol version #{inspect(version)}; supported versions: #{Enum.join(@supported_versions, ", ")}"

      profile ->
        profile
    end
  end

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
      # The 2026 elicitation specification explicitly defines an empty
      # `elicitation` object as backwards-compatible form-mode support.
      _form -> ["elicitation"]
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

  @doc false
  def required_input_capability_paths(input_requests) when is_map(input_requests) do
    input_requests
    |> Map.values()
    |> Enum.flat_map(&input_request_capability_paths/1)
    |> Enum.uniq()
  end

  @doc false
  def missing_input_capabilities(client_capabilities, input_requests)
      when is_map(input_requests) do
    input_requests
    |> required_input_capability_paths()
    |> Enum.reject(&capability?(client_capabilities, &1))
    |> capabilities_map()
  end

  @doc false
  def capabilities_map(paths) when is_list(paths) do
    Enum.reduce(paths, %{}, fn path, required ->
      deep_merge_capabilities(required, capability_path_map(path))
    end)
  end

  defp input_request_capability_paths(request) when is_map(request) do
    method = metadata_value(request, :method)
    params = metadata_value(request, :params, %{})

    base =
      case required_client_capability(method, params) do
        nil -> []
        path -> [path]
      end

    base ++ sampling_capability_paths(method, params)
  end

  defp input_request_capability_paths(_request), do: []

  defp sampling_capability_paths("sampling/createMessage", params) when is_map(params) do
    []
    |> maybe_add_capability_path(
      Map.has_key?(params, "tools") or Map.has_key?(params, :tools) or
        Map.has_key?(params, "toolChoice") or Map.has_key?(params, :toolChoice),
      ["sampling", "tools"]
    )
    |> maybe_add_capability_path(
      metadata_value(params, :includeContext) in ["thisServer", "allServers"],
      ["sampling", "context"]
    )
  end

  defp sampling_capability_paths(_method, _params), do: []

  defp maybe_add_capability_path(paths, true, path), do: [path | paths]
  defp maybe_add_capability_path(paths, false, _path), do: paths

  defp capability_path_map(path) do
    path
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn segment, nested -> %{to_string(segment) => nested} end)
  end

  defp deep_merge_capabilities(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge_capabilities(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end

  defp metadata_value(metadata, key, default) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end
end
