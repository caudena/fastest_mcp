defmodule FastestMCP.Providers.Skills.Gemini do
  @moduledoc """
  Builds a default skills-directory provider for Gemini skill folders.

  This module is a thin adapter over `FastestMCP.Providers.SkillsDirectory`.
  Its job is to point the shared directory scanner at the conventional paths
  and file layout used by this editor or agent environment.

  Use these helpers when you want to expose locally installed skills as MCP
  resources without hard-coding directory conventions in your application.
  """

  alias FastestMCP.Providers.SkillsDirectory

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    home = Keyword.get(opts, :home, System.user_home!())

    SkillsDirectory.new(
      roots: [Path.join(home, ".gemini/skills")],
      reload: Keyword.get(opts, :reload, false),
      supporting_files: Keyword.get(opts, :supporting_files, :template)
    )
  end
end
