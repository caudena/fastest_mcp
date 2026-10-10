defmodule FastestMCP.Providers.Skills do
  @moduledoc """
  Skills providers for the conventional skill folders of coding agents.

      provider = FastestMCP.Providers.Skills.vendor(:codex, reload: true)

  See `FastestMCP.Providers.SkillsDirectory` for explicit roots.
  """

  alias FastestMCP.Providers.SkillsDirectory

  # Home roots are relative to `:home`; a system root can be replaced with
  # `:system_root`. Earlier roots win when skill names collide.
  @vendor_roots %{
    claude: [home: ".claude/skills"],
    codex: [system: "/etc/codex/skills", home: ".codex/skills"],
    copilot: [home: ".copilot/skills"],
    cursor: [home: ".cursor/skills"],
    gemini: [home: ".gemini/skills"],
    goose: [home: ".config/agents/skills"],
    opencode: [home: ".config/opencode/skills"],
    vscode: [home: ".copilot/skills"]
  }

  @doc """
  Builds a `FastestMCP.Providers.SkillsDirectory` provider over the skill
  folders of `vendor`:

  | Vendor | Roots |
  | --- | --- |
  | `:claude` | `~/.claude/skills` |
  | `:codex` | `/etc/codex/skills`, then `~/.codex/skills` |
  | `:copilot`, `:vscode` | `~/.copilot/skills` |
  | `:cursor` | `~/.cursor/skills` |
  | `:gemini` | `~/.gemini/skills` |
  | `:goose` | `~/.config/agents/skills` |
  | `:opencode` | `~/.config/opencode/skills` |

  `:home` replaces the home directory and `:system_root` the Codex system root;
  the other options are those of `FastestMCP.Providers.SkillsDirectory.new/1`.
  An unknown vendor raises `ArgumentError`.
  """
  def vendor(vendor, opts \\ []) do
    roots =
      Map.get(@vendor_roots, vendor) ||
        raise ArgumentError,
              "unknown skills vendor #{inspect(vendor)}, expected one of " <>
                inspect(Map.keys(@vendor_roots))

    {home, opts} = Keyword.pop_lazy(opts, :home, &System.user_home!/0)
    {system_root, opts} = Keyword.pop(opts, :system_root)

    roots =
      Enum.map(roots, fn
        {:home, path} -> Path.join(home, path)
        {:system, path} -> system_root || path
      end)

    SkillsDirectory.new(Keyword.put(opts, :roots, roots))
  end
end
