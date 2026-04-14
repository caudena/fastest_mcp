defmodule FastestMCP.Resources.Content do
  @moduledoc """
  Resource content helper with MIME and metadata support.

  This helper exists for resource handlers that need explicit control over
  per-item MIME types and per-item metadata.

  Accepted content forms:

    * UTF-8 binaries - treated as text
    * non-UTF-8 binaries - treated as binary blobs
    * maps, lists, tuples, and structs - JSON encoded as text

  Use `FastestMCP.Resources.Binary.new/2` when you need to force binary
  handling for data that happens to be valid UTF-8.
  """

  defstruct content: nil, mime_type: nil, meta: nil

  @type t :: %__MODULE__{
          content: String.t() | binary(),
          mime_type: String.t(),
          meta: map() | nil
        }

  @doc "Builds a normalized resource content item."
  def new(content, opts \\ []) do
    {normalized_content, inferred_mime_type} = normalize_content(content, opts)

    %__MODULE__{
      content: normalized_content,
      mime_type: Keyword.get(opts, :mime_type, inferred_mime_type),
      meta: normalize_optional_map(Keyword.get(opts, :meta))
    }
  end

  @doc "Normalizes content-like values into `%FastestMCP.Resources.Content{}`."
  def from(%__MODULE__{} = content), do: content
  def from(content), do: new(content)

  @doc "Returns whether the content should be encoded as text in the transport payload."
  def textual?(%__MODULE__{content: content, mime_type: mime_type}) when is_binary(content) do
    String.valid?(content) and not binary_mime_type?(mime_type)
  end

  def textual?(%__MODULE__{}), do: false

  defp normalize_content(content, opts) when is_binary(content) do
    force_binary? = Keyword.get(opts, :binary, false)

    cond do
      force_binary? ->
        {content, "application/octet-stream"}

      String.valid?(content) ->
        {content, "text/plain"}

      true ->
        {content, "application/octet-stream"}
    end
  end

  defp normalize_content(content, _opts) do
    {Jason.encode!(normalize_json(content)), "application/json"}
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json(%URI{} = value), do: URI.to_string(value)

  defp normalize_json(%MapSet{} = value),
    do: value |> MapSet.to_list() |> Enum.map(&normalize_json/1)

  defp normalize_json(%_{} = value), do: value |> Map.from_struct() |> normalize_json()

  defp normalize_json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {normalize_key(key), normalize_json(item)} end)

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&normalize_json/1)

  defp normalize_json(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(map) when is_map(map), do: Map.new(map)

  defp normalize_optional_map(other) do
    raise ArgumentError, "resource content meta must be a map, got #{inspect(other)}"
  end

  defp binary_mime_type?(mime_type) when is_binary(mime_type) do
    not String.starts_with?(mime_type, "text/") and mime_type != "application/json"
  end

  defp binary_mime_type?(_mime_type), do: false
end
