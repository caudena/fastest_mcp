defmodule FastestMCP.Protocol.Content do
  @moduledoc false

  alias FastestMCP.Base64
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.URI, as: ProtocolURI

  @base_types ~w(text image audio resource resource_link)

  def block!(block, opts \\ [])

  def block!(block, opts) when is_map(block) do
    block = JSONValue.stringify_keys(block)
    type = Map.get(block, "type")

    unless type in @base_types do
      invalid!(opts, "content block has unsupported type #{inspect(type)}")
    end

    block
    |> validate_common!(opts)
    |> validate_type!(type, opts)
  end

  def block!(_block, opts), do: invalid!(opts, "content block must be an object")

  def prompt_block!(content, opts \\ []) do
    opts = Keyword.put(opts, :require_resource_mime, true)

    case content do
      [single] ->
        block!(single, opts)

      list when is_list(list) ->
        invalid!(opts, "prompt messages require exactly one content block")

      block ->
        block!(block, opts)
    end
  end

  def resource_contents!(resource, opts \\ [])

  def resource_contents!(resource, opts) when is_map(resource) do
    resource = JSONValue.stringify_keys(resource)
    require_non_empty_string!(resource, "uri", opts)
    require_absolute_uri!(resource, "uri", opts)
    validate_resource_mime!(resource, opts)
    validate_meta!(resource, opts)

    case {Map.fetch(resource, "text"), Map.fetch(resource, "blob")} do
      {{:ok, text}, :error} when is_binary(text) ->
        resource

      {:error, {:ok, blob}} when is_binary(blob) ->
        validate_base64!(blob, "resource blob", opts)
        resource

      _other ->
        invalid!(opts, "resource contents require exactly one string text or blob field")
    end
  end

  def resource_contents!(_resource, opts),
    do: invalid!(opts, "resource contents must be an object")

  defp validate_common!(block, opts) do
    validate_meta!(block, opts)
    validate_annotations!(Map.get(block, "annotations"), opts)
    block
  end

  defp validate_type!(block, "text", opts) do
    require_string!(block, "text", opts)
    block
  end

  defp validate_type!(block, type, opts) when type in ["image", "audio"] do
    require_non_empty_string!(block, "data", opts)
    require_non_empty_string!(block, "mimeType", opts)
    require_mime_type!(block, "mimeType", type, opts)
    validate_base64!(Map.fetch!(block, "data"), "#{type} data", opts)
    block
  end

  defp validate_type!(block, "resource", opts) do
    Map.update!(block, "resource", &resource_contents!(&1, opts))
  rescue
    KeyError -> invalid!(opts, "embedded resource content requires resource")
  end

  defp validate_type!(block, "resource_link", opts) do
    require_non_empty_string!(block, "uri", opts)
    require_absolute_uri!(block, "uri", opts)
    require_non_empty_string!(block, "name", opts)
    optional_string!(block, "title", opts)
    optional_string!(block, "description", opts)
    optional_mime_type!(block, "mimeType", opts)
    optional_integer!(block, "size", opts)
    validate_icons!(Map.get(block, "icons"), opts)
    block
  end

  defp validate_meta!(block, opts) do
    source =
      case Keyword.get(opts, :source, :server) do
        :peer -> :peer
        :protocol -> :protocol
        _application -> :application
      end

    case Meta.validate(Map.get(block, "_meta"),
           source: source,
           allowed_reserved: Keyword.get(opts, :allowed_reserved_meta, [])
         ) do
      {:ok, _meta} -> :ok
      {:error, reason} -> invalid!(opts, reason)
    end
  end

  defp validate_annotations!(nil, _opts), do: :ok

  defp validate_annotations!(annotations, opts) when is_map(annotations) do
    annotations = JSONValue.stringify_keys(annotations)

    case Map.get(annotations, "audience") do
      nil ->
        :ok

      values when is_list(values) ->
        unless Enum.all?(values, &(&1 in ["user", "assistant"])),
          do: invalid!(opts, "annotations audience contains an invalid role")

      _other ->
        invalid!(opts, "annotations audience must be an array")
    end

    case Map.get(annotations, "priority") do
      nil -> :ok
      value when is_number(value) and value >= 0 and value <= 1 -> :ok
      _other -> invalid!(opts, "annotations priority must be between 0 and 1")
    end

    optional_string!(annotations, "lastModified", opts)
  end

  defp validate_annotations!(_annotations, opts),
    do: invalid!(opts, "annotations must be an object")

  defp validate_icons!(nil, _opts), do: :ok

  defp validate_icons!(icons, opts) when is_list(icons) do
    Enum.each(icons, fn
      icon when is_map(icon) ->
        icon = JSONValue.stringify_keys(icon)
        require_non_empty_string!(icon, "src", opts)
        optional_mime_type!(icon, "mimeType", opts)

        case Map.get(icon, "sizes") do
          nil ->
            :ok

          sizes when is_list(sizes) ->
            unless Enum.all?(sizes, &is_binary/1),
              do: invalid!(opts, "icon sizes must contain strings")

          _other ->
            invalid!(opts, "icon sizes must be an array")
        end

        case Map.get(icon, "theme") do
          nil -> :ok
          theme when theme in ["light", "dark"] -> :ok
          _other -> invalid!(opts, "icon theme must be light or dark")
        end

      _other ->
        invalid!(opts, "icons must contain objects")
    end)
  end

  defp validate_icons!(_icons, opts), do: invalid!(opts, "icons must be an array")

  defp require_string!(map, key, opts) do
    unless is_binary(Map.get(map, key)), do: invalid!(opts, "#{key} must be a string")
  end

  defp require_non_empty_string!(map, key, opts) do
    unless is_binary(Map.get(map, key)) and Map.get(map, key) != "",
      do: invalid!(opts, "#{key} must be a non-empty string")
  end

  defp require_absolute_uri!(map, key, opts) do
    unless ProtocolURI.valid?(Map.get(map, key)),
      do: invalid!(opts, "#{key} must be an absolute RFC 3986 URI")
  end

  defp optional_string!(map, key, opts) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _other -> invalid!(opts, "#{key} must be a string")
    end
  end

  defp validate_resource_mime!(resource, opts) do
    if Keyword.get(opts, :require_resource_mime, false) do
      require_non_empty_string!(resource, "mimeType", opts)
      require_mime_type!(resource, "mimeType", nil, opts)
    else
      optional_mime_type!(resource, "mimeType", opts)
    end
  end

  defp require_mime_type!(map, key, nil, opts) do
    unless MIME.valid?(Map.get(map, key)),
      do: invalid!(opts, "#{key} must be a valid MIME type")
  end

  defp require_mime_type!(map, key, expected_type, opts) do
    unless MIME.type?(Map.get(map, key), expected_type),
      do: invalid!(opts, "#{key} must be a valid #{expected_type} MIME type")
  end

  defp optional_mime_type!(map, key, opts) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_binary(value) -> require_mime_type!(map, key, nil, opts)
      _other -> invalid!(opts, "#{key} must be a string")
    end
  end

  defp optional_integer!(map, key, opts) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_integer(value) -> :ok
      _other -> invalid!(opts, "#{key} must be an integer")
    end
  end

  defp validate_base64!(value, label, opts) do
    unless Base64.valid?(value), do: invalid!(opts, "#{label} must be base64-encoded")
  end

  defp invalid!(opts, message) do
    code =
      if Keyword.get(opts, :source, :server) == :peer, do: :invalid_params, else: :internal_error

    raise Error, code: code, message: message
  end
end
