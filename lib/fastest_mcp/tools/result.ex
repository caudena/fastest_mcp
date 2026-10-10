defmodule FastestMCP.Tools.Result do
  @moduledoc """
  Canonical tool result helper.

  Tool handlers can return plain Elixir values for the common case, but
  `FastestMCP.Tools.Result` is the explicit shape when the tool needs:

    * human-readable content that should not be derived automatically
    * structured content for machine consumers
    * result-level metadata
    * an explicit `isError` flag

  When you provide `structured_content` without `content`, FastestMCP derives a
  readable text block from the structured payload so MCP transports still emit a
  complete tool result.

  ## Examples

  ```elixir
  FastestMCP.Tools.Result.new("Release checklist generated",
    structured_content: %{status: "ok"}
  )

  FastestMCP.Tools.Result.new(
    [
      %{type: "text", text: "Release checklist generated"},
      %{type: "text", text: "Warnings: 0"}
    ],
    structured_content: %{status: "ok", warnings: 0},
    meta: %{source: "release-planner"}
  )
  ```
  """

  import FastestMCP.Util, only: [maybe_put: 3, optional_map!: 2, string_keys: 1]

  defstruct content: nil,
            structured_content: nil,
            structured_content_present?: false,
            meta: nil,
            is_error: nil,
            extra: %{}

  @type t :: %__MODULE__{
          content: any(),
          structured_content: any(),
          structured_content_present?: boolean(),
          meta: map() | nil,
          is_error: boolean() | nil,
          extra: map()
        }

  @doc "Builds a normalized tool result."
  def new(content \\ nil, opts \\ []) do
    structured_content_present? =
      Keyword.has_key?(opts, :structured_content) or Keyword.has_key?(opts, :structuredContent)

    structured_content =
      opts
      |> Keyword.get_lazy(:structured_content, fn -> Keyword.get(opts, :structuredContent) end)
      |> normalize_structured_content()

    if is_nil(content) and not structured_content_present? do
      raise ArgumentError, "tool result requires content or structured_content"
    end

    %__MODULE__{
      content: if(is_nil(content), do: structured_content, else: content),
      structured_content: structured_content,
      structured_content_present?: structured_content_present?,
      meta: optional_map!(Keyword.get(opts, :meta), "tool result meta"),
      is_error: normalize_optional_boolean(Keyword.get(opts, :is_error))
    }
  end

  @doc "Normalizes result-like values into `%FastestMCP.Tools.Result{}`."
  def from(%__MODULE__{} = result), do: result

  # Application code gives envelopes with atom or string keys, in Elixir or
  # MCP spelling.
  def from(%{} = value) do
    value = string_keys(value)

    structured_content =
      case Enum.find(["structured_content", "structuredContent"], &Map.has_key?(value, &1)) do
        nil -> []
        key -> [structured_content: value[key]]
      end

    new(
      value["content"],
      structured_content ++
        [
          meta: Map.get(value, "_meta", value["meta"]),
          is_error: Map.get(value, "is_error", value["isError"])
        ]
    )
  end

  def from(value), do: new(value)

  @doc "Builds an explicit envelope from a validated, string-keyed MCP result."
  def from_raw(%{} = raw) do
    %__MODULE__{
      content: Map.get(raw, "content", []),
      structured_content: Map.get(raw, "structuredContent"),
      structured_content_present?: Map.has_key?(raw, "structuredContent"),
      meta: Map.get(raw, "_meta"),
      is_error: Map.get(raw, "isError"),
      extra: Map.drop(raw, ["content", "structuredContent", "isError"])
    }
  end

  @doc "Converts the helper struct into the normalized tool-result map used by the runtime."
  def to_map(%__MODULE__{} = result) do
    %{}
    |> Map.put(:content, result.content)
    |> maybe_put_structured_content(result)
    |> maybe_put(:meta, result.meta)
    |> maybe_put(:isError, result.is_error)
  end

  defp normalize_structured_content(nil), do: nil
  defp normalize_structured_content(value), do: FastestMCP.JSONValue.normalize(value)

  defp normalize_optional_boolean(nil), do: nil
  defp normalize_optional_boolean(value) when is_boolean(value), do: value

  defp normalize_optional_boolean(other) do
    raise ArgumentError, "tool result is_error must be a boolean, got #{inspect(other)}"
  end

  defp maybe_put_structured_content(map, %{structured_content_present?: true} = result),
    do: Map.put(map, :structuredContent, result.structured_content)

  defp maybe_put_structured_content(map, _result), do: map
end
