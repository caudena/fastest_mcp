defmodule FastestMCP.Apps do
  @moduledoc """
  MCP-facing helpers for the MCP Apps extension.

  These helpers describe tools and `ui://` HTML resources. Rendering, iframe
  sandboxing, CSP enforcement, consent, and View-to-Host `postMessage` traffic
  belong to the consuming browser/native Host and are intentionally outside
  FastestMCP's server and connected-client transports.

  HTML is intentionally opaque here. The caller must supply a complete, valid
  HTML5 document; FastestMCP does not add a doctype or implement an HTML parser.
  CSP source strings are likewise preserved for the consuming Host to enforce.
  """

  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.URI, as: ProtocolURI
  alias FastestMCP.Resources.Content
  alias FastestMCP.Resources.Result

  @mime_type "text/html;profile=mcp-app"
  @visibility ~w(model app)
  @csp_keys ~w(connectDomains resourceDomains frameDomains baseUriDomains)
  @permission_keys ~w(camera microphone geolocation clipboardWrite)

  @doc "Returns the Apps extension identifier."
  def extension_id, do: Extensions.apps()

  @doc "Returns the stable MCP Apps HTML resource media type."
  def mime_type, do: @mime_type

  @doc "Returns whether a MIME value identifies an MCP Apps document."
  def mime_type?(value), do: same_mime?(value)

  @doc "Builds client capability settings for MCP Apps."
  def client_settings(mime_types \\ [@mime_type]) do
    Extensions.normalize(%{extension_id() => %{"mimeTypes" => List.wrap(mime_types)}})
    |> Map.fetch!(extension_id())
  end

  @doc "Builds canonical `_meta` linking a tool to a UI resource."
  def tool_meta(resource_uri, opts \\ []) do
    ui =
      %{"resourceUri" => validate_ui_uri!(resource_uri)}
      |> maybe_put("visibility", normalize_visibility(Keyword.get(opts, :visibility)))

    merge_meta(Keyword.get(opts, :meta), %{"ui" => ui})
  end

  @doc "Builds resource metadata for CSP, permissions, origin, and presentation."
  def resource_meta(opts \\ []) do
    ui =
      %{}
      |> maybe_put("csp", normalize_csp(Keyword.get(opts, :csp)))
      |> maybe_put("permissions", normalize_permissions(Keyword.get(opts, :permissions)))
      |> maybe_put("domain", normalize_optional_string(Keyword.get(opts, :domain), :domain))
      |> maybe_put(
        "prefersBorder",
        normalize_optional_boolean(Keyword.get(opts, :prefers_border))
      )

    merge_meta(Keyword.get(opts, :meta), %{"ui" => ui})
  end

  @doc "Builds one opaque HTML5 resource content item suitable for `resources/read`."
  def content(resource_uri, html, opts \\ []) when is_binary(html) do
    Content.new(html,
      uri: validate_ui_uri!(resource_uri),
      mime_type: @mime_type,
      meta: resource_meta(opts)
    )
  end

  @doc "Builds a resource result containing one MCP App document."
  def result(resource_uri, html, opts \\ []) do
    Result.new([content(resource_uri, html, opts)])
  end

  @doc "Reads canonical or deprecated Apps tool linkage metadata."
  def resource_uri(meta) when is_map(meta) do
    ui = map_value(meta, :ui, %{})
    map_value(ui, :resourceUri) || map_value(meta, :"ui/resourceUri")
  end

  def resource_uri(_other), do: nil

  @doc false
  def advertised?(client_capabilities) do
    case Extensions.settings(client_capabilities, extension_id()) do
      %{"mimeTypes" => mime_types} when is_list(mime_types) ->
        Enum.any?(mime_types, &same_mime?/1)

      _other ->
        false
    end
  end

  @doc false
  def enabled?(server_extensions), do: Extensions.enabled?(server_extensions, extension_id())

  @doc false
  def negotiated?(client_capabilities, server_extensions) do
    enabled?(server_extensions) and advertised?(client_capabilities)
  end

  @doc false
  def filter_meta(meta, client_capabilities, server_extensions) when is_map(meta) do
    if negotiated?(client_capabilities, server_extensions) do
      meta
    else
      meta
      |> Map.delete(:ui)
      |> Map.delete("ui")
      |> Map.delete(:"ui/resourceUri")
      |> Map.delete("ui/resourceUri")
    end
  end

  def filter_meta(other, _client_capabilities, _server_extensions), do: other

  defp validate_ui_uri!(uri) do
    uri = uri |> to_string() |> ProtocolURI.validate!("MCP Apps resource URI")

    if String.starts_with?(uri, "ui://") do
      uri
    else
      raise ArgumentError, "MCP Apps resource URI must use the ui:// scheme"
    end
  end

  defp normalize_visibility(nil), do: @visibility

  defp normalize_visibility(values) do
    values = values |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    if values != [] and Enum.all?(values, &(&1 in @visibility)) do
      values
    else
      raise ArgumentError, "Apps visibility must contain model and/or app"
    end
  end

  defp normalize_csp(nil), do: nil

  defp normalize_csp(csp) when is_map(csp) or is_list(csp) do
    csp = Map.new(csp, fn {key, values} -> {to_string(key), values} end)

    Enum.each(csp, fn {key, values} ->
      unless key in @csp_keys and is_list(values) and
               Enum.all?(values, &(is_binary(&1) and &1 != "")) do
        raise ArgumentError,
              "Apps CSP #{inspect(key)} must be a list of non-empty source strings"
      end
    end)

    csp
  end

  defp normalize_csp(other),
    do: raise(ArgumentError, "Apps CSP must be a map, got #{inspect(other)}")

  defp normalize_permissions(nil), do: nil

  defp normalize_permissions(value) when is_map(value) or is_list(value) do
    Map.new(value, fn {key, settings} ->
      key = to_string(key)

      unless key in @permission_keys and settings == %{} do
        raise ArgumentError,
              "Apps permission #{inspect(key)} must be one of #{Enum.join(@permission_keys, ", ")} with empty settings"
      end

      {key, %{}}
    end)
  end

  defp normalize_permissions(other) do
    raise ArgumentError, "Apps permissions must be a map, got #{inspect(other)}"
  end

  defp normalize_optional_string(nil, _field), do: nil
  defp normalize_optional_string(value, _field) when is_binary(value) and value != "", do: value

  defp normalize_optional_string(value, field) do
    raise ArgumentError, "Apps #{field} must be a non-empty string, got #{inspect(value)}"
  end

  defp normalize_optional_boolean(nil), do: nil
  defp normalize_optional_boolean(value) when is_boolean(value), do: value

  defp normalize_optional_boolean(value) do
    raise ArgumentError, "Apps prefers_border must be a boolean, got #{inspect(value)}"
  end

  defp same_mime?(value) when is_binary(value) do
    value |> String.downcase() |> String.replace(~r/\s+/, "") == @mime_type
  end

  defp same_mime?(_other), do: false

  defp merge_meta(nil, addition), do: addition

  defp merge_meta(meta, addition) when is_map(meta) do
    Map.merge(Map.new(meta, fn {key, value} -> {to_string(key), value} end), addition)
  end

  defp merge_meta(other, _addition) do
    raise ArgumentError, "Apps metadata must be a map, got #{inspect(other)}"
  end

  defp map_value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
