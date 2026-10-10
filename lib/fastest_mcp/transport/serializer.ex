defmodule FastestMCP.Transport.Serializer do
  @moduledoc false

  import FastestMCP.Util, only: [maybe_put: 3, string_keys: 1]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Apps
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
  alias FastestMCP.Prompts.Message, as: PromptMessage
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.Protocol.Content
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Tools.Result, as: ToolResult

  # The metadata functions take a component's `Component.metadata/1` map or
  # its struct, both with atom keys.

  def tool_metadata(tool, opts \\ []) do
    %{
      "name" => tool.name,
      "title" => Map.get(tool, :title) || tool.name,
      "description" => Map.get(tool, :description) || "",
      "inputSchema" => Map.get(tool, :input_schema) || %{"type" => "object"}
    }
    |> maybe_put("icons", normalize_json(Map.get(tool, :icons)))
    |> maybe_put("annotations", normalize_json(Map.get(tool, :annotations)))
    |> maybe_put("outputSchema", output_schema(Map.get(tool, :output_schema), opts))
    |> maybe_put(
      "execution",
      unless(modern?(opts), do: normalize_json(Map.get(tool, :execution)))
    )
    |> Map.put("_meta", component_meta(tool, %{}))
  end

  def resource_metadata(resource) do
    %{
      "uri" => resource.uri,
      "name" => Map.get(resource, :name) || resource.uri,
      "description" => Map.get(resource, :description) || ""
    }
    |> maybe_put("title", Map.get(resource, :title))
    |> maybe_put("icons", normalize_json(Map.get(resource, :icons)))
    |> maybe_put("annotations", normalize_json(Map.get(resource, :annotations)))
    |> maybe_put("mimeType", Map.get(resource, :mime_type))
    |> maybe_put("size", Map.get(resource, :size))
    |> Map.put("_meta", component_meta(resource, %{}))
  end

  def resource_template_metadata(template) do
    %{
      "uriTemplate" => template.uri_template,
      "name" => Map.get(template, :name) || template.uri_template,
      "description" => Map.get(template, :description) || ""
    }
    |> maybe_put("title", Map.get(template, :title))
    |> maybe_put("icons", normalize_json(Map.get(template, :icons)))
    |> maybe_put("annotations", normalize_json(Map.get(template, :annotations)))
    |> maybe_put("mimeType", Map.get(template, :mime_type))
    |> Map.put(
      "_meta",
      component_meta(template, %{
        "parameters" => normalize_json(Map.get(template, :parameters) || %{})
      })
    )
  end

  def prompt_metadata(prompt) do
    %{
      "name" => prompt.name,
      "description" => Map.get(prompt, :description) || "",
      "arguments" =>
        Enum.map(Map.get(prompt, :arguments) || [], fn argument ->
          %{
            "name" => argument.name,
            "description" => argument[:description] || "",
            "required" => Map.get(argument, :required, false)
          }
          |> maybe_put("title", argument[:title])
        end)
    }
    |> maybe_put("title", Map.get(prompt, :title))
    |> maybe_put("icons", normalize_json(Map.get(prompt, :icons)))
    |> Map.put("_meta", component_meta(prompt, %{}))
  end

  def tool_result(result, tool \\ nil), do: tool_result(result, tool, [])

  def tool_result(%ToolResult{} = result, tool, opts) do
    content =
      if is_nil(result.content) and result.structured_content_present?,
        do: [Content.text(result.structured_content)],
        else: result.content

    result.extra
    |> normalize_json()
    |> Map.put("content", normalize_content_payload(content))
    |> put_structured_content(result, opts)
    |> maybe_put("_meta", Meta.output!(result.meta))
    |> put_is_error(result.is_error)
    |> validate_apps_tool_fallback!(tool, opts)
  end

  def tool_result(result, tool, opts) do
    payload =
      cond do
        is_binary(result) ->
          %{"content" => [Content.text(result)]}

        true ->
          normalized = normalize_json(result)

          payload = %{"content" => [Content.text(normalized)]}

          if modern?(opts) do
            Map.put(payload, "structuredContent", normalized)
          else
            maybe_put(payload, "structuredContent", map_or_nil(normalized))
          end
      end

    validate_apps_tool_fallback!(payload, tool, opts)
  end

  def resource_result(uri, mime_type, result), do: resource_result(uri, mime_type, result, [])

  def resource_result(uri, mime_type, result, opts) do
    cond do
      match?(%ResourceResult{}, result) ->
        result.extra
        |> normalize_json()
        |> Map.put(
          "contents",
          Enum.map(result.contents, &resource_content(uri, mime_type, &1, opts))
        )
        |> maybe_put("_meta", apps_meta(result.meta, opts))

      match?(%ResourceContent{}, result) ->
        %{"contents" => [resource_content(uri, mime_type, result, opts)]}

      true ->
        %{"contents" => [Map.put(resource_body(mime_type, result), "uri", uri)]}
    end
  end

  def prompt_result(%PromptResult{} = result) do
    result.extra
    |> normalize_json()
    |> Map.put("messages", Enum.map(result.messages, &prompt_message/1))
    |> maybe_put("description", result.description)
    |> maybe_put("_meta", Meta.output!(result.meta))
  end

  def prompt_result(value) when is_binary(value), do: prompt_result(PromptResult.new(value))
  def prompt_result(value), do: prompt_result(PromptResult.new(JSONValue.encode!(value)))

  defp prompt_message(%PromptMessage{} = message),
    do: prompt_message(message.role, message.content, message.meta)

  # A validated wire message of `PromptResult.from_raw/1`.
  defp prompt_message(%{} = message) do
    prompt_message(
      Map.get(message, "role", "user"),
      Map.get(message, "content", ""),
      message["_meta"]
    )
  end

  defp prompt_message(other), do: %{"role" => "user", "content" => Content.text(other)}

  defp prompt_message(role, content, meta) do
    unless role in ["user", "assistant", :user, :assistant] do
      raise Error, code: :internal_error, message: "prompt message role must be user or assistant"
    end

    %{"role" => to_string(role), "content" => prompt_content(content)}
    |> maybe_put("_meta", Meta.output!(meta))
  end

  defp prompt_content(content) when is_list(content),
    do: content |> Enum.map(&Content.normalize/1) |> Content.prompt_block!()

  defp prompt_content(content), do: Content.normalize(content)

  # A declared type is authoritative; without one, the value names its type.
  defp resource_body(mime_type, value) when is_binary(value) do
    if String.valid?(value) and not MIME.binary?(mime_type) do
      %{"text" => value, "mimeType" => mime_type || "text/plain"}
    else
      %{"blob" => Base.encode64(value), "mimeType" => mime_type || "application/octet-stream"}
    end
  end

  defp resource_body(mime_type, value) do
    %{
      "text" => JSON.encode!(normalize_json(value)),
      "mimeType" => mime_type || "application/json"
    }
  end

  defp resource_content(uri, default_mime_type, %ResourceContent{} = content, opts) do
    resource_content(
      uri,
      default_mime_type,
      %{
        "uri" => content.uri,
        "content" => content.content,
        "mime_type" => content.mime_type,
        "_meta" => content.meta
      },
      opts
    )
  end

  # A content map of `ResourceResult.from/1` (application data, with atom or
  # string keys, naming the type `mime_type`) or `from_raw/1` (wire contents,
  # such as a proxied read, naming it `mimeType`). A content's own type wins
  # over the resource's declared one.
  defp resource_content(uri, default_mime_type, %{} = content, opts) do
    content = string_keys(content)
    mime_type = content["mimeType"] || content["mime_type"] || default_mime_type

    base =
      %{"uri" => content["uri"] || uri}
      |> maybe_put("mimeType", mime_type)
      |> maybe_put("_meta", apps_meta(content["_meta"] || content["meta"], opts))

    case content do
      %{"text" => text} -> Map.put(base, "text", text)
      %{"blob" => blob} -> Map.put(base, "blob", Content.encode_binary(blob))
      %{} -> Map.merge(base, resource_body(mime_type, content["content"]))
    end
  end

  defp apps_meta(meta, opts) do
    meta
    |> Meta.output!()
    |> Apps.filter_meta(
      Keyword.get(opts, :client_capabilities, %{}),
      Keyword.get(opts, :server_extensions, %{})
    )
  end

  # `tool` is the component that ran, a task's component descriptor, or nil.
  defp validate_apps_tool_fallback!(payload, tool, opts) do
    apps_tool? =
      Apps.enabled?(Keyword.get(opts, :server_extensions, %{})) and
        is_map(tool) and
        not is_nil(Apps.resource_uri(Map.get(tool, :meta)))

    if apps_tool? and Map.get(payload, "content") == [] do
      raise Error,
        code: :internal_error,
        message: "MCP Apps tools must return a non-empty content fallback"
    end

    payload
  end

  defp normalize_content_payload(value) when is_list(value),
    do: Enum.map(value, &Content.normalize/1)

  defp normalize_content_payload(nil) do
    raise Error, code: :internal_error, message: "tool content must be an array or content value"
  end

  defp normalize_content_payload(value), do: [Content.normalize(value)]

  defp normalize_json(value), do: JSONValue.stringify_keys(value)

  # The component's `_meta` with its tags and version (and `extras`) under
  # `_meta.fastestmcp`, after the upstream extensions there.
  defp component_meta(component, extras) do
    meta =
      case Map.get(component, :meta) do
        nil -> %{}
        meta -> meta |> Meta.validate!() |> normalize_json()
      end

    upstream =
      case meta["fastestmcp"] do
        %{} = fastestmcp ->
          Map.reject(fastestmcp, fn {key, _value} -> String.starts_with?(key, "_") end)

        _other ->
          %{}
      end

    compat =
      %{
        "tags" => normalize_tags(Map.get(component, :tags)),
        "version" => normalize_optional_string(Map.get(component, :version))
      }
      |> Map.merge(extras)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.put(meta, "fastestmcp", Map.merge(upstream, compat))
  end

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

  defp modern?(opts) when is_list(opts),
    do: is_modern(Keyword.get(opts, :protocol_version))

  defp modern?(_opts), do: false

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp put_structured_content(payload, %ToolResult{structured_content_present?: false}, _opts),
    do: payload

  defp put_structured_content(payload, %ToolResult{structured_content: value}, opts) do
    value = normalize_json(value)

    if modern?(opts),
      do: Map.put(payload, "structuredContent", value),
      else: maybe_put(payload, "structuredContent", map_or_nil(value))
  end

  # The legacy wire takes object output schemas only.
  defp output_schema(%{"type" => type} = schema, opts) when type not in [nil, "object"],
    do: if(modern?(opts), do: schema)

  defp output_schema(schema, _opts), do: schema

  defp put_is_error(payload, nil), do: payload
  defp put_is_error(payload, value) when is_boolean(value), do: Map.put(payload, "isError", value)

  defp put_is_error(_payload, _value) do
    raise Error, code: :internal_error, message: "tool isError must be a boolean"
  end
end
