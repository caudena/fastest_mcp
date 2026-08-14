defmodule FastestMCP.Client.ToolResult do
  @moduledoc """
  Stable, protocol-faithful result returned by `FastestMCP.Client.call_tool_result/4`.

  Unlike the compatibility projection returned by `FastestMCP.Client.call_tool/4`,
  this struct preserves the complete validated wire result and distinguishes an
  absent `structuredContent` field from an explicitly returned JSON `null`.
  """

  @enforce_keys [:raw]
  defstruct content: [],
            structured_content: nil,
            structured_content_present?: false,
            meta: nil,
            is_error: false,
            raw: %{}

  @type t :: %__MODULE__{
          content: [map()],
          structured_content: term(),
          structured_content_present?: boolean(),
          meta: map() | nil,
          is_error: boolean(),
          raw: map()
        }

  @doc false
  @spec from_raw(map()) :: t()
  def from_raw(%{} = raw) do
    %__MODULE__{
      content: Map.get(raw, "content", []),
      structured_content: Map.get(raw, "structuredContent"),
      structured_content_present?: Map.has_key?(raw, "structuredContent"),
      meta: Map.get(raw, "_meta"),
      is_error: Map.get(raw, "isError", false) == true,
      raw: raw
    }
  end
end
