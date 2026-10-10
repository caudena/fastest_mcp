defmodule FastestMCP.Resources.Result do
  @moduledoc """
  Canonical resource result helper.

  Resource handlers can return plain values for the common case, but
  `FastestMCP.Resources.Result` is the explicit shape when you need:

    * multiple content items
    * per-item MIME types
    * per-item metadata
    * result-level metadata

  Accepted content inputs:

    * UTF-8 binaries
    * non-UTF-8 binaries
    * list of `FastestMCP.Resources.Content`
  """

  import FastestMCP.Util, only: [optional_map!: 2, string_keys: 1]

  alias FastestMCP.Resources.Content

  defstruct contents: [], meta: nil, extra: %{}

  @type t :: %__MODULE__{
          contents: [Content.t()],
          meta: map() | nil,
          extra: map()
        }

  @doc "Builds a normalized resource result."
  def new(contents, opts \\ []) do
    %__MODULE__{
      contents: normalize_contents(contents),
      meta: optional_map!(Keyword.get(opts, :meta), "resource result meta")
    }
  end

  @doc "Normalizes result-like values into `%FastestMCP.Resources.Result{}`."
  def from(%__MODULE__{} = result), do: result

  # Application code gives envelopes with atom or string keys.
  def from(%{} = value) do
    case string_keys(value) do
      %{"contents" => contents} = envelope ->
        %__MODULE__{contents: contents, meta: Map.get(envelope, "_meta", envelope["meta"])}

      _contents ->
        new(value)
    end
  end

  def from(contents), do: new(contents)

  @doc "Builds an explicit envelope from a validated MCP resource result."
  def from_raw(%{} = raw) do
    %__MODULE__{
      contents: Map.fetch!(raw, "contents"),
      meta: Map.get(raw, "_meta"),
      extra: Map.delete(raw, "contents")
    }
  end

  defp normalize_contents(contents) when is_binary(contents), do: [Content.new(contents)]

  defp normalize_contents(contents) when is_list(contents) do
    Enum.with_index(contents)
    |> Enum.map(fn {item, index} ->
      if match?(%Content{}, item) do
        Content.from(item)
      else
        raise ArgumentError,
              "contents[#{index}] must be FastestMCP.Resources.Content, got #{inspect(item)}"
      end
    end)
  end

  defp normalize_contents(%Content{} = _content) do
    raise ArgumentError,
          "contents must be a string, binary, or list[FastestMCP.Resources.Content], got a bare content item"
  end

  defp normalize_contents(other) do
    raise ArgumentError,
          "contents must be a string, binary, or list[FastestMCP.Resources.Content], got #{inspect(other)}"
  end
end
