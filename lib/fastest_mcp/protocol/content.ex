defmodule FastestMCP.Protocol.Content do
  @moduledoc false

  import FastestMCP.Util, only: [maybe_put: 3, string_keys: 1]

  alias FastestMCP.Base64
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.URI, as: ProtocolURI

  @base_types ~w(text image audio resource resource_link)

  # One content value a handler returned, as a validated wire content block.
  # Content maps (application data, with atom or string keys) keep their
  # protocol fields, media and blob data are base64-encoded unless they
  # already are, and any other value becomes text.
  def normalize(value) when is_map(value) do
    case string_keys(value) do
      %{"type" => type} = block -> block |> wire_block(to_string(type)) |> block!()
      _data -> text(value)
    end
  end

  def normalize(value), do: text(value)

  def text(value), do: %{"type" => "text", "text" => stringify(value)}

  def encode_binary(value) when is_binary(value),
    do: if(Base64.valid?(value), do: value, else: Base.encode64(value))

  def encode_binary(_value), do: invalid!([], "media and blob data must be binary")

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

  # `block` has string keys and may use the Elixir names `mime_type` and
  # `meta`; an unsupported type is left for `block!/2` to reject.
  defp wire_block(block, type) when type in @base_types do
    base =
      %{"type" => type}
      |> maybe_put("annotations", JSONValue.stringify_keys(block["annotations"]))
      |> maybe_put("_meta", Meta.output!(block["_meta"] || block["meta"]))

    case type do
      "text" ->
        Map.put(base, "text", block["text"])

      media when media in ["image", "audio"] ->
        base
        |> Map.put("data", encode_binary(block["data"]))
        |> maybe_put("mimeType", block["mimeType"] || block["mime_type"])

      "resource" ->
        Map.put(base, "resource", wire_resource(block["resource"]))

      "resource_link" ->
        link =
          case block["resource_link"] || block["resourceLink"] do
            %{} = link -> string_keys(link)
            _direct -> block
          end

        base
        |> Map.put("uri", link["uri"])
        |> maybe_put("name", link["name"])
        |> maybe_put("title", link["title"])
        |> maybe_put("description", link["description"])
        |> maybe_put("mimeType", link["mimeType"] || link["mime_type"])
        |> maybe_put("size", link["size"])
        |> maybe_put("icons", JSONValue.stringify_keys(link["icons"]))
        |> maybe_put("annotations", JSONValue.stringify_keys(link["annotations"]))
        |> maybe_put("_meta", Meta.output!(link["_meta"] || link["meta"]))
    end
  end

  defp wire_block(block, _type), do: block

  defp wire_resource(%{} = resource) do
    resource = string_keys(resource)

    %{"uri" => resource["uri"]}
    |> maybe_put("mimeType", resource["mimeType"] || resource["mime_type"])
    |> maybe_put("text", resource["text"])
    |> maybe_put("blob", wire_blob(resource["blob"]))
    |> maybe_put("_meta", Meta.output!(resource["_meta"] || resource["meta"]))
  end

  defp wire_resource(_resource),
    do: invalid!([], "embedded resource content requires an object")

  defp wire_blob(nil), do: nil
  defp wire_blob(blob), do: encode_binary(blob)

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) do
    case JSONValue.stringify_keys(value) do
      text when is_binary(text) -> text
      normalized -> JSON.encode!(normalized)
    end
  end

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

  defp validate_type!(%{"resource" => resource} = block, "resource", opts),
    do: %{block | "resource" => resource_contents!(resource, opts)}

  defp validate_type!(_block, "resource", opts),
    do: invalid!(opts, "embedded resource content requires resource")

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
