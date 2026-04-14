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

  alias FastestMCP.Resources.Content

  defstruct contents: [], meta: nil

  @type t :: %__MODULE__{
          contents: [Content.t()],
          meta: map() | nil
        }

  @doc "Builds a normalized resource result."
  def new(contents, opts \\ []) do
    %__MODULE__{
      contents: normalize_contents(contents),
      meta: normalize_optional_map(Keyword.get(opts, :meta))
    }
  end

  @doc "Normalizes result-like values into `%FastestMCP.Resources.Result{}`."
  def from(%__MODULE__{} = result), do: result
  def from(contents), do: new(contents)

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

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(map) when is_map(map), do: Map.new(map)

  defp normalize_optional_map(other) do
    raise ArgumentError, "resource result meta must be a map, got #{inspect(other)}"
  end
end
