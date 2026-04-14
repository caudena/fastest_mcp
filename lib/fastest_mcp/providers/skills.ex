defmodule FastestMCP.Providers.Skills do
  @moduledoc """
  Backwards-compatible alias for the skills directory provider.

  Providers are the extension point FastestMCP uses when components come
  from somewhere other than the server struct itself. This module implements
  one concrete provider shape and is usually wrapped by `FastestMCP.Provider`
  when mounted into a server.

  That lets the runtime treat local, mounted, OpenAPI, and skills-backed
  component sources the same way once they enter the provider layer.
  """

  alias FastestMCP.Providers.SkillsDirectory

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []), do: SkillsDirectory.new(opts)
end
