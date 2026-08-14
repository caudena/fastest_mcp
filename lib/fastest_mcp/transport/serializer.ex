defmodule FastestMCP.Transport.Serializer do
  @moduledoc """
  Serializes component metadata and results into transport-facing payloads.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  @content_block_types MapSet.new(["text", "image", "audio", "resource", "resource_link"])

  alias FastestMCP.Apps
  alias FastestMCP.Base64
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
  alias FastestMCP.Prompts.Message, as: PromptMessage
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.Protocol.Content
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Tools.OutputSchema
  alias FastestMCP.Tools.Result, as: ToolResult

  @doc "Serializes tool metadata for transport exposure."
  def tool_metadata(tool, opts \\ []) do
    output_schema = OutputSchema.prepare(fetch(tool, :output_schema))

    %{
      "name" => fetch(tool, :name),
      "title" => fetch(tool, :title) || fetch(tool, :name),
      "description" => fetch(tool, :description) || "",
      "inputSchema" => fetch(tool, :input_schema) || %{"type" => "object"}
    }
    |> maybe_put("icons", normalize_json(fetch(tool, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(tool, :annotations)))
    |> maybe_put("outputSchema", compatible_output_schema(output_schema, opts))
    |> maybe_put(
      "execution",
      if(modern?(opts), do: nil, else: normalize_json(fetch(tool, :execution)))
    )
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(fetch(tool, :meta), fetch(tool, :tags), fetch(tool, :version), %{})
      )
    )
  end

  @doc "Serializes resource metadata for transport exposure."
  def resource_metadata(resource) do
    %{
      "uri" => fetch(resource, :uri),
      "name" => fetch(resource, :name) || fetch(resource, :uri),
      "description" => fetch(resource, :description) || ""
    }
    |> maybe_put("title", fetch(resource, :title))
    |> maybe_put("icons", normalize_json(fetch(resource, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(resource, :annotations)))
    |> maybe_put("mimeType", fetch(resource, :mime_type))
    |> maybe_put("size", fetch(resource, :size))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(
          fetch(resource, :meta),
          fetch(resource, :tags),
          fetch(resource, :version),
          %{}
        )
      )
    )
  end

  @doc "Serializes resource-template metadata for transport exposure."
  def resource_template_metadata(template) do
    %{
      "uriTemplate" => fetch(template, :uri_template),
      "name" => fetch(template, :name) || fetch(template, :uri_template),
      "description" => fetch(template, :description) || ""
    }
    |> maybe_put("title", fetch(template, :title))
    |> maybe_put("icons", normalize_json(fetch(template, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(template, :annotations)))
    |> maybe_put("mimeType", fetch(template, :mime_type))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(
          fetch(template, :meta),
          fetch(template, :tags),
          fetch(template, :version),
          %{
            "parameters" => fetch(template, :parameters) || %{}
          }
        )
      )
    )
  end

  @doc "Serializes prompt metadata for transport exposure."
  def prompt_metadata(prompt) do
    %{
      "name" => fetch(prompt, :name),
      "description" => fetch(prompt, :description) || "",
      "arguments" =>
        Enum.map(fetch(prompt, :arguments) || [], fn argument ->
          %{
            "name" => fetch(argument, :name),
            "description" => fetch(argument, :description) || "",
            "required" => fetch(argument, :required, false)
          }
          |> maybe_put("title", fetch(argument, :title))
        end)
    }
    |> maybe_put("title", fetch(prompt, :title))
    |> maybe_put("icons", normalize_json(fetch(prompt, :icons)))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(fetch(prompt, :meta), fetch(prompt, :tags), fetch(prompt, :version), %{})
      )
    )
  end

  @doc "Serializes a tool result for transport exposure."
  def tool_result(result, tool \\ nil), do: tool_result(result, tool, [])

  @doc false
  def tool_result(%ToolResult{} = result, tool, opts) do
    result
    |> ToolResult.to_map()
    |> tool_result(tool, opts)
  end

  def tool_result(result, tool, opts) do
    payload =
      cond do
        explicit_tool_result?(result) ->
          structured_content = structured_content_payload!(result)
          structured_content = compatible_structured_content(structured_content, opts)

          content = tool_result_content_payload(result, structured_content)

          %{}
          |> Map.put("content", normalize_content_payload(content))
          |> put_explicit_structured_content(result, structured_content, opts)
          |> maybe_put("_meta", normalize_output_meta(fetch_meta(result)))
          |> put_is_error(result)

        content_block?(result) ->
          %{"content" => [normalize_content_block(result)]}

        is_list(result) and Enum.any?(result, &contentish?/1) ->
          %{"content" => normalize_content_payload(result)}

        is_binary(result) ->
          %{"content" => [text_block(result)]}

        true ->
          normalized = normalize_json(result)

          payload = %{"content" => [text_block(normalized)]}

          if modern?(opts) do
            Map.put(payload, "structuredContent", normalized)
          else
            maybe_put(payload, "structuredContent", map_or_nil(normalized))
          end
      end

    validate_apps_tool_fallback!(payload, tool, opts)
  end

  @doc "Serializes a resource result for transport exposure."
  def resource_result(uri, mime_type, result), do: resource_result(uri, mime_type, result, [])

  @doc false
  def resource_result(uri, mime_type, result, opts) do
    cond do
      match?(%ResourceResult{}, result) ->
        resource_result(
          uri,
          mime_type,
          %{contents: result.contents, meta: result.meta},
          opts
        )

      is_map(result) and not is_nil(fetch(result, :contents)) ->
        %{
          "contents" =>
            Enum.map(fetch(result, :contents), &resource_content(uri, mime_type, &1, opts))
        }
        |> maybe_put("_meta", apps_meta(fetch_meta(result), opts))

      match?(%ResourceContent{}, result) ->
        %{"contents" => [resource_content(uri, mime_type, result, opts)]}

      true ->
        %{
          "contents" => [
            %{"uri" => uri}
            |> maybe_put("mimeType", mime_type)
            |> Map.merge(resource_body(mime_type, result))
          ]
        }
    end
  end

  @doc "Serializes a prompt result for transport exposure."
  def prompt_result(result) do
    result =
      case result do
        %PromptResult{} = prompt_result -> PromptResult.to_map(prompt_result)
        other -> other
      end

    messages =
      cond do
        is_map(result) and not is_nil(fetch(result, :messages)) ->
          Enum.map(fetch(result, :messages), &prompt_message/1)

        is_list(result) ->
          Enum.map(result, &prompt_message/1)

        true ->
          [prompt_message(result)]
      end

    %{"messages" => messages}
    |> maybe_put("description", if(is_map(result), do: fetch(result, :description)))
    |> maybe_put("_meta", if(is_map(result), do: normalize_output_meta(fetch_meta(result))))
  end

  defp prompt_message(message) when is_map(message) do
    message =
      case message do
        %PromptMessage{} = prompt_message -> PromptMessage.to_map(prompt_message)
        other -> other
      end

    role = fetch(message, :role, "user")

    unless role in ["user", "assistant", :user, :assistant] do
      raise Error, code: :internal_error, message: "prompt message role must be user or assistant"
    end

    %{
      "role" => to_string(role),
      "content" => prompt_content(fetch(message, :content, ""))
    }
    |> maybe_put("_meta", normalize_output_meta(fetch_meta(message)))
  end

  defp prompt_message(message) when is_binary(message) do
    %{"role" => "user", "content" => text_block(message)}
  end

  defp prompt_message(other) do
    %{"role" => "user", "content" => text_block(other)}
  end

  defp prompt_content(content) when is_list(content),
    do: content |> Enum.map(&normalize_content_item/1) |> Content.prompt_block!()

  defp prompt_content(content) when is_map(content) do
    normalize_content_item(content)
  end

  defp prompt_content(content), do: text_block(content)

  defp resource_body(mime_type, value) when is_binary(value) do
    cond do
      binary_mime_type?(mime_type) ->
        %{"blob" => Base.encode64(value)}

      String.valid?(value) ->
        %{"text" => value}

      true ->
        %{"blob" => Base.encode64(value)}
    end
    |> maybe_put("mimeType", mime_type)
  end

  defp resource_body(_mime_type, value) do
    %{"text" => JSON.encode!(normalize_json(value))}
  end

  defp resource_content(uri, default_mime_type, %ResourceContent{} = content, opts) do
    resource_content(
      uri,
      default_mime_type,
      %{
        uri: Map.get(content, :uri),
        content: content.content,
        mime_type: content.mime_type,
        meta: content.meta
      },
      opts
    )
  end

  defp resource_content(uri, default_mime_type, %{} = content, opts) do
    content_uri = fetch(content, :uri) || uri
    mime_type = fetch(content, :mime_type) || default_mime_type

    base =
      %{"uri" => content_uri}
      |> maybe_put("mimeType", mime_type)
      |> maybe_put("_meta", apps_meta(fetch_meta(content), opts))

    cond do
      Map.has_key?(content, :text) or Map.has_key?(content, "text") ->
        Map.put(base, "text", fetch(content, :text))

      Map.has_key?(content, :blob) or Map.has_key?(content, "blob") ->
        Map.put(base, "blob", encode_binary(fetch(content, :blob)))

      true ->
        Map.merge(base, resource_body(mime_type, fetch(content, :content)))
    end
  end

  defp apps_meta(meta, opts) do
    meta
    |> normalize_output_meta()
    |> Apps.filter_meta(
      Keyword.get(opts, :client_capabilities, %{}),
      Keyword.get(opts, :server_extensions, %{})
    )
  end

  defp explicit_tool_result?(value) when is_map(value) do
    Enum.any?(
      [
        :content,
        "content",
        :structuredContent,
        "structuredContent",
        :structured_content,
        "structured_content"
      ],
      &Map.has_key?(value, &1)
    )
  end

  defp explicit_tool_result?(_value), do: false

  defp tool_result_content_payload(result, structured_content) do
    if Map.has_key?(result, :content) or Map.has_key?(result, "content") do
      fetch(result, :content)
    else
      [text_block(structured_content)]
    end
  end

  defp validate_apps_tool_fallback!(payload, tool, opts) do
    apps_tool? =
      Apps.enabled?(Keyword.get(opts, :server_extensions, %{})) and
        is_map(tool) and
        not is_nil(Apps.resource_uri(fetch_meta(tool)))

    if apps_tool? and Map.get(payload, "content") == [] do
      raise Error,
        code: :internal_error,
        message: "MCP Apps tools must return a non-empty content fallback"
    end

    payload
  end

  defp structured_content_payload!(result) do
    key =
      Enum.find(
        [:structuredContent, "structuredContent", :structured_content, "structured_content"],
        &Map.has_key?(result, &1)
      )

    case key do
      nil -> nil
      key -> result |> Map.get(key) |> normalize_structured_content!()
    end
  end

  defp normalize_content_payload(value) when is_list(value) do
    Enum.map(value, &normalize_content_item/1)
  end

  defp normalize_content_payload(nil) do
    raise Error, code: :internal_error, message: "tool content must be an array or content value"
  end

  defp normalize_content_payload(value), do: [normalize_content_item(value)]

  defp normalize_content_item(value) do
    cond do
      content_block?(value) ->
        normalize_content_block(value)

      is_map(value) and (Map.has_key?(value, :type) or Map.has_key?(value, "type")) ->
        value |> normalize_json() |> Content.block!()

      true ->
        text_block(value)
    end
  end

  defp normalize_content_block(block) do
    type = block |> fetch(:type) |> to_string()

    base =
      %{"type" => type}
      |> maybe_put("annotations", normalize_json(fetch(block, :annotations)))
      |> maybe_put("_meta", normalize_output_meta(fetch_meta(block)))

    normalized =
      case type do
        "text" ->
          Map.put(base, "text", fetch(block, :text))

        "image" ->
          base
          |> Map.put("data", encode_binary(fetch(block, :data)))
          |> maybe_put("mimeType", fetch(block, :mimeType) || fetch(block, :mime_type))

        "audio" ->
          base
          |> Map.put("data", encode_binary(fetch(block, :data)))
          |> maybe_put("mimeType", fetch(block, :mimeType) || fetch(block, :mime_type))

        "resource" ->
          Map.put(base, "resource", normalize_resource_block(fetch(block, :resource)))

        "resource_link" ->
          resource_link = fetch(block, :resource_link) || fetch(block, :resourceLink) || block

          base
          |> Map.put("uri", fetch(resource_link, :uri))
          |> maybe_put("name", fetch(resource_link, :name))
          |> maybe_put("title", fetch(resource_link, :title))
          |> maybe_put("description", fetch(resource_link, :description))
          |> maybe_put(
            "mimeType",
            fetch(resource_link, :mimeType) || fetch(resource_link, :mime_type)
          )
          |> maybe_put("size", fetch(resource_link, :size))
          |> maybe_put("icons", normalize_json(fetch(resource_link, :icons)))
          |> maybe_put("annotations", normalize_json(fetch(resource_link, :annotations)))
          |> maybe_put("_meta", normalize_output_meta(fetch_meta(resource_link)))

        _other ->
          base
      end

    Content.block!(normalized)
  end

  defp normalize_resource_block(resource) when is_map(resource) do
    %{"uri" => fetch(resource, :uri)}
    |> maybe_put("mimeType", fetch(resource, :mimeType) || fetch(resource, :mime_type))
    |> maybe_put("text", fetch(resource, :text))
    |> maybe_put("blob", encode_optional_binary(fetch(resource, :blob)))
    |> maybe_put("_meta", normalize_output_meta(fetch_meta(resource)))
  end

  defp normalize_resource_block(_resource) do
    raise Error, code: :internal_error, message: "embedded resource content requires an object"
  end

  defp contentish?(value), do: content_block?(value)

  defp content_block?(value) when is_map(value) do
    value
    |> fetch(:type)
    |> then(&MapSet.member?(@content_block_types, to_string(&1 || "")))
  end

  defp content_block?(_value), do: false

  defp text_block(value), do: %{"type" => "text", "text" => stringify(value)}

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) do
    normalized = normalize_json(value)

    if is_binary(normalized) do
      normalized
    else
      JSON.encode!(normalized)
    end
  end

  defp normalize_json(value), do: JSONValue.stringify_keys(value)

  defp encode_binary(value) when is_binary(value) do
    if Base64.valid?(value), do: value, else: Base.encode64(value)
  end

  defp encode_binary(_value) do
    raise Error, code: :internal_error, message: "media and blob data must be binary"
  end

  defp encode_optional_binary(nil), do: nil
  defp encode_optional_binary(value), do: encode_binary(value)

  defp component_meta(meta, tags, version, compat_updates) do
    merge_transport_meta(
      meta,
      %{
        "tags" => normalize_tags(tags),
        "version" => normalize_optional_string(version)
      }
      |> Map.merge(compat_updates)
    )
  end

  defp merge_transport_meta(meta, compat_updates) do
    meta = normalize_meta_map(meta)
    upstream_compat = transport_meta_source(meta)

    compat_meta =
      upstream_compat
      |> Map.merge(Map.reject(compat_updates, fn {_key, value} -> is_nil(value) end))

    Map.put(meta, "fastestmcp", compat_meta)
  end

  defp transport_meta_source(meta) do
    normalize_compat_meta(Map.get(meta, "fastestmcp"))
  end

  defp normalize_meta_map(nil), do: %{}

  defp normalize_meta_map(meta) when is_map(meta) do
    meta
    |> Meta.validate!()
    |> normalize_json()
  end

  defp normalize_output_meta(nil), do: nil

  defp normalize_output_meta(meta) when is_map(meta) do
    case Meta.validate(meta, allowed_reserved: ["io.modelcontextprotocol/related-task"]) do
      {:ok, normalized} ->
        normalize_json(normalized)

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "handler produced invalid MCP metadata: #{reason}"
    end
  end

  defp normalize_output_meta(_meta) do
    raise Error, code: :internal_error, message: "handler produced non-object MCP metadata"
  end

  defp normalize_compat_meta(%{} = meta) do
    meta
    |> normalize_json()
    |> Enum.reject(fn {key, _value} -> String.starts_with?(to_string(key), "_") end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_compat_meta(_value), do: %{}

  defp normalize_tags(%MapSet{} = tags) do
    tags
    |> MapSet.to_list()
    |> normalize_tags()
  end

  defp normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp binary_mime_type?(mime_type), do: MIME.binary?(mime_type)

  defp normalize_structured_content!(value), do: normalize_json(value)

  defp modern?(opts) when is_list(opts),
    do: Keyword.get(opts, :protocol_version) == "2026-07-28"

  defp modern?(_opts), do: false

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp compatible_structured_content(value, opts) do
    if modern?(opts), do: value, else: map_or_nil(value)
  end

  defp put_explicit_structured_content(payload, result, value, opts) do
    present? =
      Enum.any?(
        [:structuredContent, "structuredContent", :structured_content, "structured_content"],
        &Map.has_key?(result, &1)
      )

    if modern?(opts) and present? do
      Map.put(payload, "structuredContent", value)
    else
      maybe_put(payload, "structuredContent", value)
    end
  end

  defp compatible_output_schema(nil, _opts), do: nil

  defp compatible_output_schema(schema, opts) do
    if modern?(opts) or fetch(schema, :type) in [nil, "object"], do: schema
  end

  defp fetch(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp fetch_meta(map), do: fetch(map, :_meta) || fetch(map, :meta)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_is_error(payload, result) do
    cond do
      Map.has_key?(result, :is_error) -> put_is_error_value(payload, Map.get(result, :is_error))
      Map.has_key?(result, "is_error") -> put_is_error_value(payload, Map.get(result, "is_error"))
      Map.has_key?(result, :isError) -> put_is_error_value(payload, Map.get(result, :isError))
      Map.has_key?(result, "isError") -> put_is_error_value(payload, Map.get(result, "isError"))
      true -> payload
    end
  end

  defp put_is_error_value(payload, value) when is_boolean(value),
    do: Map.put(payload, "isError", value)

  defp put_is_error_value(_payload, _value) do
    raise Error, code: :internal_error, message: "tool isError must be a boolean"
  end
end
