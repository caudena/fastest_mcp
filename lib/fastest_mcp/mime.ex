defmodule FastestMCP.MIME do
  @moduledoc false
  # Media-type parameters such as charset are ignored when classifying, and
  # comparisons are case-insensitive.

  alias Plug.Conn.Utils, as: PlugConnUtils

  def normalize(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  def normalize(value), do: value |> to_string() |> normalize()

  def json?(value) when is_binary(value) do
    case parse_content_type(value) do
      {:ok, type, subtype, _params} ->
        type != "*" and not String.contains?(subtype, "*") and
          ((type == "application" and subtype == "json") or
             String.ends_with?(subtype, "+json"))

      :error ->
        false
    end
  end

  def json?(_value), do: false

  def accepts?(header_values, media_type) do
    case parse_content_type(to_string(media_type)) do
      {:ok, expected_type, expected_subtype, _params} ->
        header_values
        |> List.wrap()
        |> Enum.flat_map(&PlugConnUtils.list(to_string(&1)))
        |> Enum.with_index()
        |> Enum.flat_map(&accept_match(&1, expected_type, expected_subtype))
        |> effective_quality()
        |> Kernel.>(0.0)

      :error ->
        false
    end
  end

  def content_type?(value, expected) when is_binary(value) and is_binary(expected) do
    with {:ok, actual_type, actual_subtype, _actual_params} <-
           parse_content_type(value),
         {:ok, expected_type, expected_subtype, _expected_params} <-
           parse_content_type(expected) do
      actual_type == expected_type and actual_subtype == expected_subtype
    else
      :error -> false
    end
  end

  def content_type?(_value, _expected), do: false

  def valid?(value) when is_binary(value) do
    case parse_content_type(value) do
      {:ok, type, subtype, _params} ->
        type != "*" and subtype != "*" and
          not String.contains?(type, "*") and not String.contains?(subtype, "*")

      :error ->
        false
    end
  end

  def valid?(_value), do: false

  def type?(value, expected_type) when is_binary(value) and is_binary(expected_type) do
    expected_type = String.downcase(expected_type)

    case parse_content_type(value) do
      {:ok, ^expected_type, subtype, _params} ->
        subtype != "*" and not String.contains?(subtype, "*")

      _other ->
        false
    end
  end

  def type?(_value, _expected_type), do: false

  def textual?(value) when is_binary(value) do
    normalized = normalize(value)
    String.starts_with?(normalized, "text/") or json?(normalized)
  end

  def textual?(_value), do: false

  def binary?(nil), do: false
  def binary?(value), do: not textual?(value)

  defp accept_match({entry, index}, expected_type, expected_subtype) do
    case parse_media_type(entry) do
      {:ok, "*", "*", params} ->
        [{0, index, quality(params)}]

      {:ok, ^expected_type, "*", params} ->
        [{1, index, quality(params)}]

      {:ok, ^expected_type, ^expected_subtype, params} ->
        [{2, index, quality(params)}]

      _other ->
        []
    end
  end

  defp accept_match(_entry, _expected_type, _expected_subtype), do: []

  # RFC 9110 gives a more-specific media range precedence over a wildcard,
  # including when the more-specific range excludes the representation with
  # q=0. Preserve header ordering as the tie-breaker for duplicate ranges.
  defp effective_quality([]), do: 0.0

  defp effective_quality(matches) do
    matches
    |> Enum.max_by(fn {specificity, index, _quality} -> {specificity, -index} end)
    |> elem(2)
  end

  defp quality(params) when is_map(params) do
    case Map.fetch(params, "q") do
      :error ->
        1.0

      {:ok, value} ->
        case Float.parse(value) do
          {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
          _other -> 0.0
        end
    end
  end

  defp parse_content_type(value), do: PlugConnUtils.content_type(value)
  defp parse_media_type(value), do: PlugConnUtils.media_type(value)
end
