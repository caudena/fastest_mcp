defmodule FastestMCP.Resources.Text do
  @moduledoc """
  Convenience builder for text resource content.

  This module is intentionally small: it exists so examples can say "this
  resource returns text" without manually repeating MIME-type boilerplate.
  """

  alias FastestMCP.Resources.Content

  @doc "Builds text resource content."
  def new(text, opts \\ []) when is_binary(text) do
    Content.new(text, Keyword.put_new(opts, :mime_type, "text/plain"))
  end
end
