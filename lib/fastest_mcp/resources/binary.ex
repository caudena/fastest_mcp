defmodule FastestMCP.Resources.Binary do
  @moduledoc """
  Convenience builder for binary resource content.

  Use this helper when the payload should be treated as a blob even if it
  happens to be valid UTF-8.
  """

  alias FastestMCP.Resources.Content

  @doc "Builds binary resource content."
  def new(data, opts \\ []) when is_binary(data) do
    opts =
      opts
      |> Keyword.put(:binary, true)
      |> Keyword.put_new(:mime_type, "application/octet-stream")

    Content.new(data, opts)
  end
end
