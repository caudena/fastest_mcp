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

  alias FastestMCP.Prompts.Message, as: PromptMessage
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Tools.OutputSchema

  @doc "Serializes tool metadata for transport exposure."
  def tool_metadata(tool) do
    %{
      "name" => fetch(tool, :name),
      "title" => fetch(tool, :title) || fetch(tool, :name),
      "description" => fetch(tool, :description) || "",
      "inputSchema" => fetch(tool, :input_schema) || %{"type" => "object"},
      "execution" => fetch(tool, :execution) || %{}
    }
    |> maybe_put("icons", normalize_json(fetch(tool, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(tool, :annotations)))
    |> maybe_put("outputSchema", OutputSchema.prepare(fetch(tool, :output_schema)))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(fetch(tool, :meta), fetch(tool, :tags), fetch(tool, :version))
      )
    )
  end

  @doc "Serializes resource metadata for transport exposure."
  def resource_metadata(resource) do
    %{
      "uri" => fetch(resource, :uri),
      "name" => fetch(resource, :title) || fetch(resource, :uri),
      "description" => fetch(resource, :description) || ""
    }
    |> maybe_put("execution", fetch(resource, :execution))
    |> maybe_put("icons", normalize_json(fetch(resource, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(resource, :annotations)))
    |> maybe_put("mimeType", fetch(resource, :mime_type))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(fetch(resource, :meta), fetch(resource, :tags), fetch(resource, :version))
      )
    )
  end

  @doc "Serializes resource-template metadata for transport exposure."
  def resource_template_metadata(template) do
    %{
      "uriTemplate" => fetch(template, :uri_template),
      "name" => fetch(template, :title) || fetch(template, :uri_template),
      "description" => fetch(template, :description) || "",
      "parameters" => fetch(template, :parameters) || %{}
    }
    |> maybe_put("execution", fetch(template, :execution))
    |> maybe_put("icons", normalize_json(fetch(template, :icons)))
    |> maybe_put("annotations", normalize_json(fetch(template, :annotations)))
    |> maybe_put("mimeType", fetch(template, :mime_type))
    |> Map.put(
      "_meta",
      normalize_json(
        component_meta(fetch(template, :meta), fetch(template, :tags), fetch(template, :version))
      )
    )
  end

  @doc "Serializes prompt metadata for transport exposure."
  def prompt_metadata(prompt) do
    %{
      "name" => fetch(prompt, :name),
      "title" => fetch(prompt, :title) || fetch(prompt, :name),
      "description" => fetch(prompt, :description) || "",
      "arguments" =>
        Enum.map(fetch(prompt, :arguments) || [], fn argument ->
          %{
            "name" => fetch(argument, :name),
            "description" => fetch(argument, :description) || "",
            "required" => fetch(argument, :required, false)
          }
        end)
    }
    |> maybe_put("icons", normalize_json(fetch(prompt, :icons)))
  end

  @doc "Serializes a tool result for transport exposure."
  def tool_result(result, tool \\ nil)

  def tool_result(%ToolResult{} = result, tool) do
    result
    |> ToolResult.to_map()
    |> tool_result(tool)
  end

  def tool_result(result, tool) do
    payload =
      cond do
        explicit_tool_result?(result) ->
          structured_content =
            fetch(result, :structured_content) || fetch(result, :structuredContent)

          content = tool_result_content_payload(result, structured_content)

          %{}
          |> Map.put("content", normalize_content_payload(content))
          |> maybe_put("structuredContent", normalize_json(structured_content))
          |> maybe_put("meta", normalize_json(fetch(result, :meta)))
          |> maybe_put("isError", fetch_with_presence(result, :is_error, :isError))

        content_block?(result) ->
          %{"content" => [normalize_content_block(result)]}

        is_list(result) and Enum.any?(result, &contentish?/1) ->
          %{"content" => normalize_content_payload(result)}

        is_binary(result) ->
          %{"content" => [text_block(result)]}

        true ->
          normalized = normalize_json(result)

          %{
            "content" => [text_block(normalized)],
            "structuredContent" => normalized
          }
      end

    maybe_wrap_tool_result(payload, tool)
  end

  @doc "Serializes a resource result for transport exposure."
  def resource_result(uri, mime_type, result) do
    cond do
      match?(%ResourceResult{}, result) ->
        resource_result(uri, mime_type, %{
          contents: result.contents,
          meta: result.meta
        })

      is_map(result) and not is_nil(fetch(result, :contents)) ->
        %{"contents" => Enum.map(fetch(result, :contents), &resource_content(uri, mime_type, &1))}
        |> maybe_put("meta", normalize_json(fetch(result, :meta)))

      match?(%ResourceContent{}, result) ->
        %{"contents" => [resource_content(uri, mime_type, result)]}

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
    |> maybe_put("meta", if(is_map(result), do: normalize_json(fetch(result, :meta))))
  end

  defp prompt_message(message) when is_map(message) do
    message =
      case message do
        %PromptMessage{} = prompt_message -> PromptMessage.to_map(prompt_message)
        other -> other
      end

    %{
      "role" => fetch(message, :role, "user"),
      "content" => prompt_content(fetch(message, :content, ""))
    }
    |> maybe_put("meta", normalize_json(fetch(message, :meta)))
  end

  defp prompt_message(message) when is_binary(message) do
    %{"role" => "user", "content" => text_block(message)}
  end

  defp prompt_message(other) do
    %{"role" => "user", "content" => text_block(other)}
  end

  defp prompt_content(content) when is_list(content) do
    Enum.map(content, &normalize_content_item/1)
  end

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
    %{"text" => Jason.encode!(normalize_json(value))}
  end

  defp resource_content(uri, default_mime_type, %ResourceContent{} = content) do
    resource_content(uri, default_mime_type, %{
      content: content.content,
      mime_type: content.mime_type,
      meta: content.meta
    })
  end

  defp resource_content(uri, default_mime_type, %{} = content) do
    mime_type = fetch(content, :mime_type) || default_mime_type
    body = fetch(content, :content)

    %{"uri" => uri}
    |> maybe_put("mimeType", mime_type)
    |> maybe_put("meta", normalize_json(fetch(content, :meta)))
    |> Map.merge(resource_body(mime_type, body))
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
    case fetch(result, :content) do
      nil when not is_nil(structured_content) -> structured_content
      nil -> []
      value -> value
    end
  end

  defp normalize_content_payload(value) when is_list(value) do
    Enum.map(value, &normalize_content_item/1)
  end

  defp normalize_content_payload(value), do: [normalize_content_item(value)]

  defp normalize_content_item(value) do
    if content_block?(value) do
      normalize_content_block(value)
    else
      text_block(value)
    end
  end

  defp normalize_content_block(block) do
    type = fetch(block, :type)

    base =
      %{"type" => type}
      |> maybe_put("annotations", normalize_json(fetch(block, :annotations)))

    case type do
      "text" ->
        Map.put(base, "text", stringify(fetch(block, :text)))

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
        Map.put(
          base,
          "resourceLink",
          normalize_json(fetch(block, :resource_link) || fetch(block, :resourceLink))
        )

      _other ->
        base
    end
  end

  defp normalize_resource_block(resource) do
    %{"uri" => fetch(resource, :uri)}
    |> maybe_put("mimeType", fetch(resource, :mimeType) || fetch(resource, :mime_type))
    |> maybe_put("text", fetch(resource, :text))
    |> maybe_put("blob", encode_optional_binary(fetch(resource, :blob)))
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
      Jason.encode!(normalized)
    end
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json(%URI{} = value), do: URI.to_string(value)

  defp normalize_json(%MapSet{} = value) do
    value
    |> MapSet.to_list()
    |> Enum.map(&normalize_json/1)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_json/1)
  end

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize_json(item)} end)
  end

  defp normalize_json(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp encode_binary(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end

  defp encode_binary(value), do: stringify(value)

  defp encode_optional_binary(nil), do: nil
  defp encode_optional_binary(value), do: encode_binary(value)

  defp maybe_wrap_tool_result(payload, tool) when is_map(payload) do
    structured = Map.get(payload, "structuredContent")

    cond do
      is_nil(structured) ->
        payload

      not wrap_result?(tool) ->
        payload

      already_wrapped_result?(structured) ->
        Map.put(
          payload,
          "meta",
          normalize_json(merge_transport_meta(Map.get(payload, "meta"), %{"wrap_result" => true}))
        )

      true ->
        payload
        |> Map.put("structuredContent", %{"result" => structured})
        |> Map.put(
          "meta",
          normalize_json(merge_transport_meta(Map.get(payload, "meta"), %{"wrap_result" => true}))
        )
    end
  end

  defp maybe_wrap_tool_result(payload, _tool), do: payload

  defp wrap_result?(nil), do: false

  defp wrap_result?(tool) do
    tool
    |> fetch(:output_schema)
    |> OutputSchema.wrap_result?()
  end

  defp already_wrapped_result?(%{"result" => _value}), do: true
  defp already_wrapped_result?(%{result: _value}), do: true
  defp already_wrapped_result?(_value), do: false

  defp component_meta(meta, tags, version) do
    merge_transport_meta(meta, %{
      "tags" => normalize_tags(tags),
      "version" => normalize_optional_string(version)
    })
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
    |> normalize_json()
    |> Map.new()
  end

  defp normalize_compat_meta(%{} = meta) do
    meta
    |> normalize_json()
    |> Enum.reject(fn {key, _value} -> String.starts_with?(to_string(key), "_") end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_compat_meta(_value), do: %{}

  defp normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp binary_mime_type?(mime_type) when is_binary(mime_type) do
    not String.starts_with?(mime_type, "text/") and mime_type != "application/json"
  end

  defp binary_mime_type?(_mime_type), do: false

  defp fetch(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_with_presence(map, primary, secondary) do
    cond do
      Map.has_key?(map, primary) -> Map.get(map, primary)
      is_atom(secondary) and Map.has_key?(map, secondary) -> Map.get(map, secondary)
      true -> nil
    end
  end
end
