defmodule FastestMCP.MIME do
  @moduledoc """
  Shared MIME-type normalization and classification helpers.

  Parameters such as charsets are ignored when classifying a media type, and
  comparisons are case-insensitive.
  """

  @doc "Returns the normalized media type without parameters."
  def normalize(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  def normalize(value), do: value |> to_string() |> normalize()

  @doc "Returns whether the media type is JSON or uses a structured `+json` suffix."
  def json?(value) when is_binary(value) do
    normalized = normalize(value)
    normalized == "application/json" or String.ends_with?(normalized, "+json")
  end

  def json?(_value), do: false

  @doc "Returns whether an HTTP Accept header explicitly permits the media type."
  def accepts?(header_values, media_type) do
    expected = normalize(media_type)

    header_values
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ","))
    |> Enum.any?(&acceptable?(&1, expected))
  end

  @doc "Returns whether a MIME type should be transported as textual content."
  def textual?(value) when is_binary(value) do
    normalized = normalize(value)
    String.starts_with?(normalized, "text/") or json?(normalized)
  end

  def textual?(_value), do: false

  @doc "Returns whether a MIME type should be transported as binary content."
  def binary?(nil), do: false
  def binary?(value), do: not textual?(value)

  defp acceptable?(entry, expected) do
    [media_range | parameters] = String.split(entry, ";")
    normalize(media_range) == expected and quality(parameters) > 0.0
  end

  defp quality(parameters) do
    Enum.find_value(parameters, 1.0, fn parameter ->
      case String.split(parameter, "=", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == "q" do
            case Float.parse(String.trim(value)) do
              {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
              _other -> 0.0
            end
          end

        _other ->
          nil
      end
    end)
  end
end
