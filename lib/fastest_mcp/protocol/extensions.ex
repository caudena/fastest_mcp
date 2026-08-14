defmodule FastestMCP.Protocol.Extensions do
  @moduledoc """
  Normalization and identifiers for MCP extensions.

  The extension capability is intentionally an open map. FastestMCP validates
  the settings it understands and preserves unknown reverse-DNS identifiers so
  applications can negotiate third-party extensions without an SDK release.
  """

  @apps "io.modelcontextprotocol/ui"
  @tasks "io.modelcontextprotocol/tasks"
  @oauth_client_credentials "io.modelcontextprotocol/oauth-client-credentials"
  @enterprise_managed_authorization "io.modelcontextprotocol/enterprise-managed-authorization"

  @doc "Official MCP Apps extension identifier."
  def apps, do: @apps

  @doc "Official MCP Tasks extension identifier."
  def tasks, do: @tasks

  @doc "Official OAuth Client Credentials extension identifier."
  def oauth_client_credentials, do: @oauth_client_credentials

  @doc "Official Enterprise-Managed Authorization extension identifier."
  def enterprise_managed_authorization, do: @enterprise_managed_authorization

  @doc "Normalizes an open extension settings map."
  def normalize(nil), do: %{}

  def normalize(extensions) when is_map(extensions) or is_list(extensions) do
    Map.new(extensions, fn {identifier, settings} ->
      identifier = normalize_identifier!(identifier)
      settings = normalize_settings!(identifier, settings)
      {identifier, settings}
    end)
  end

  def normalize(other) do
    raise ArgumentError,
          "extensions must be a map of identifiers to settings, got #{inspect(other)}"
  end

  @doc "Returns whether one extension is declared in a capability map."
  def enabled?(capabilities_or_extensions, identifier) do
    identifier = to_string(identifier)

    capabilities_or_extensions
    |> extension_map()
    |> Map.has_key?(identifier)
  end

  @doc "Returns normalized settings for one extension, or nil when absent."
  def settings(capabilities_or_extensions, identifier) do
    capabilities_or_extensions
    |> extension_map()
    |> Map.get(to_string(identifier))
  end

  @doc false
  def for_profile(extensions, :modern), do: normalize(extensions)

  def for_profile(extensions, :legacy) do
    extensions
    |> normalize()
    |> Map.take([@apps])
  end

  @doc false
  def declare_oauth_grant(extensions, oauth_opts) do
    extensions = normalize(extensions)

    case oauth_grant(oauth_opts) do
      :client_credentials -> Map.put_new(extensions, @oauth_client_credentials, %{})
      :enterprise_managed -> Map.put_new(extensions, @enterprise_managed_authorization, %{})
      _authorization_code_or_invalid -> extensions
    end
  end

  defp extension_map(%{} = value) do
    value = stringify_map(value)

    case Map.get(value, "extensions") do
      %{} = extensions -> extensions
      _other -> value
    end
  end

  defp extension_map(_other), do: %{}

  defp oauth_grant(opts) when is_list(opts) do
    case Keyword.get(opts, :grant, :authorization_code) do
      {:client_credentials, _grant_opts} -> :client_credentials
      {:enterprise_managed, _grant_opts} -> :enterprise_managed
      _authorization_code_or_invalid -> :authorization_code
    end
  end

  defp oauth_grant(_opts), do: :authorization_code

  defp normalize_identifier!(identifier) when is_atom(identifier),
    do: normalize_identifier!(Atom.to_string(identifier))

  defp normalize_identifier!(identifier) when is_binary(identifier) and identifier != "" do
    if String.contains?(identifier, "/") do
      identifier
    else
      raise ArgumentError,
            "extension identifier must use a reverse-DNS vendor/name form, got #{inspect(identifier)}"
    end
  end

  defp normalize_identifier!(other) do
    raise ArgumentError, "extension identifier must be a non-empty string, got #{inspect(other)}"
  end

  defp normalize_settings!(identifier, settings) when is_map(settings) do
    settings = stringify_map(settings)

    case identifier do
      @apps -> validate_apps_settings!(settings)
      @tasks -> validate_empty_settings!(identifier, settings)
      @oauth_client_credentials -> validate_empty_settings!(identifier, settings)
      @enterprise_managed_authorization -> validate_empty_settings!(identifier, settings)
      _known_or_third_party -> settings
    end
  end

  defp normalize_settings!(identifier, other) do
    raise ArgumentError,
          "extension #{inspect(identifier)} settings must be an object, got #{inspect(other)}"
  end

  defp validate_apps_settings!(settings) do
    unknown_keys = Map.keys(settings) -- ["mimeTypes"]

    if unknown_keys != [] do
      raise ArgumentError,
            "MCP Apps settings contain unsupported keys: #{Enum.join(unknown_keys, ", ")}"
    end

    case Map.get(settings, "mimeTypes") do
      nil ->
        settings

      mime_types when is_list(mime_types) ->
        unless Enum.all?(mime_types, &(is_binary(&1) and &1 != "")) do
          raise ArgumentError, "MCP Apps mimeTypes must contain only non-empty strings"
        end

        settings

      other ->
        raise ArgumentError, "MCP Apps mimeTypes must be a list, got #{inspect(other)}"
    end
  end

  defp validate_empty_settings!(_identifier, settings) when map_size(settings) == 0,
    do: settings

  defp validate_empty_settings!(identifier, settings) do
    raise ArgumentError,
          "extension #{inspect(identifier)} settings must be an empty object, got #{inspect(settings)}"
  end

  defp stringify_map(map) do
    Map.new(map, fn {key, value} ->
      value = if is_map(value), do: stringify_map(value), else: value
      {to_string(key), value}
    end)
  end
end
