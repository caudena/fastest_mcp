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

  alias FastestMCP.JSONValue
  alias FastestMCP.MIME

  defstruct uri: nil, content: nil, mime_type: nil, meta: nil

  @type t :: %__MODULE__{
          uri: String.t() | nil,
          content: String.t() | binary(),
          mime_type: String.t(),
          meta: map() | nil
        }

  @doc "Builds a normalized resource content item."
  def new(content, opts \\ []) do
    {normalized_content, inferred_mime_type} = normalize_content(content, opts)

    %__MODULE__{
      uri: normalize_optional_uri(Keyword.get(opts, :uri)),
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
    {JSONValue.encode!(content), "application/json"}
  end

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(map) when is_map(map), do: Map.new(map)

  defp normalize_optional_map(other) do
    raise ArgumentError, "resource content meta must be a map, got #{inspect(other)}"
  end

  defp normalize_optional_uri(nil), do: nil
  defp normalize_optional_uri(uri) when is_binary(uri) and uri != "", do: uri

  defp normalize_optional_uri(other) do
    raise ArgumentError, "resource content uri must be a non-empty string, got #{inspect(other)}"
  end

  defp binary_mime_type?(mime_type), do: MIME.binary?(mime_type)
end
