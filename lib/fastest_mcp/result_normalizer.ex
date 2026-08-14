defmodule FastestMCP.ResultNormalizer do
  @moduledoc """
  Normalizes raw handler return values into transport-safe result shapes.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.JSONValue
  alias FastestMCP.Tools.Result, as: ToolResult

  @content_block_types MapSet.new(["text", "image", "audio", "resource", "resource_link"])

  @doc "Normalizes tool output into the transport result shape."
  def normalize_tool(%ToolResult{} = value) do
    value
    |> ToolResult.to_map()
    |> normalize_tool()
  end

  def normalize_tool(value) do
    cond do
      explicit_tool_result?(value) ->
        normalize_explicit_tool_result(value)

      content_block?(value) ->
        %{content: [normalize_content_block(value)]}

      content_list?(value) ->
        %{content: Enum.map(value, &normalize_content_item/1)}

      true ->
        normalize_json_value(value)
    end
  end

  @doc "Normalizes a generic value into a transport-safe result."
  def normalize_value(value), do: normalize_json_value(value)

  defp explicit_tool_result?(%{} = value) do
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

  defp normalize_explicit_tool_result(%{} = value) do
    Enum.into(value, %{}, fn {key, field_value} ->
      normalized =
        case key do
          key when key in [:content, "content"] ->
            normalize_content_payload(field_value)

          key
          when key in [
                 :structuredContent,
                 "structuredContent",
                 :structured_content,
                 "structured_content"
               ] ->
            normalize_structured_content!(field_value)

          key when key in [:data, "data"] ->
            normalize_json_value(field_value)

          _other ->
            normalize_json_value(field_value)
        end

      {key, normalized}
    end)
  end

  defp normalize_content_payload(value) when is_list(value) do
    Enum.map(value, &normalize_content_item/1)
  end

  defp normalize_content_payload(value), do: [normalize_content_item(value)]

  defp content_list?(value) when is_list(value) do
    value != [] and Enum.any?(value, &content_block?/1)
  end

  defp content_list?(_value), do: false

  defp content_block?(%{} = value) do
    value
    |> Map.get(:type, Map.get(value, "type"))
    |> then(&MapSet.member?(@content_block_types, to_string(&1 || "")))
  end

  defp content_block?(_value), do: false

  defp normalize_content_item(value) do
    if content_block?(value) do
      normalize_content_block(value)
    else
      %{type: "text", text: stringify_content(value)}
    end
  end

  defp normalize_content_block(%{} = value) do
    value =
      Enum.into(value, %{}, fn {key, field_value} ->
        normalized =
          case {Map.get(value, :type, Map.get(value, "type")), key} do
            {type, key} when type in ["image", "audio"] and key in [:data, "data"] ->
              normalize_binary_field(field_value)

            {"resource", key} when key in [:resource, "resource"] ->
              normalize_resource_content(field_value)

            {"text", key} when key in [:text, "text"] ->
              stringify_content(field_value)

            _other ->
              normalize_json_value(field_value)
          end

        {key, normalized}
      end)

    value
  end

  defp normalize_resource_content(%{} = resource) do
    Enum.into(resource, %{}, fn {key, value} ->
      normalized =
        case key do
          key when key in [:blob, "blob"] -> normalize_binary_field(value)
          _other -> normalize_json_value(value)
        end

      {key, normalized}
    end)
  end

  defp normalize_resource_content(value), do: normalize_json_value(value)

  defp normalize_json_value(value), do: JSONValue.normalize(value)

  defp normalize_structured_content!(nil), do: nil
  defp normalize_structured_content!(value), do: normalize_json_value(value)

  defp normalize_binary_field(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end

  defp normalize_binary_field(value), do: normalize_json_value(value)

  defp stringify_content(value) do
    normalized = normalize_json_value(value)

    if is_binary(normalized) do
      normalized
    else
      JSON.encode!(normalized)
    end
  rescue
    _error -> inspect(normalized_fallback(value))
  end

  defp normalized_fallback(value) do
    normalize_json_value(value)
  rescue
    _error -> value
  end
end
