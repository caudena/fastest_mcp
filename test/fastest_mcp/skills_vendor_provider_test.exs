defmodule FastestMCP.SkillsVendorProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Providers.Skills.Claude
  alias FastestMCP.Providers.Skills.Codex
  alias FastestMCP.Providers.Skills.Copilot
  alias FastestMCP.Providers.Skills.Cursor
  alias FastestMCP.Providers.Skills.Gemini
  alias FastestMCP.Providers.Skills.Goose
  alias FastestMCP.Providers.Skills.OpenCode
  alias FastestMCP.Providers.Skills.VSCode

  test "vendor providers use the expected roots and options" do
    home = "/tmp/fake-home"

    assert Claude.new(home: home).roots == [Path.join(home, ".claude/skills")]
    assert Cursor.new(home: home).roots == [Path.join(home, ".cursor/skills")]
    assert VSCode.new(home: home).roots == [Path.join(home, ".copilot/skills")]
    assert Gemini.new(home: home).roots == [Path.join(home, ".gemini/skills")]
    assert Goose.new(home: home).roots == [Path.join(home, ".config/agents/skills")]
    assert Copilot.new(home: home).roots == [Path.join(home, ".copilot/skills")]
    assert OpenCode.new(home: home).roots == [Path.join(home, ".config/opencode/skills")]

    codex =
      Codex.new(
        home: home,
        system_root: "/etc/codex/skills",
        reload: true,
        supporting_files: :resources
      )

    assert codex.roots == ["/etc/codex/skills", Path.join(home, ".codex/skills")]
    assert codex.reload == true
    assert codex.supporting_files == :resources
    assert codex.main_file_name == "SKILL.md"
  end

  test "vendor providers handle nonexistent roots gracefully" do
    providers = [
      Claude.new(home: "/tmp/no-home"),
      Cursor.new(home: "/tmp/no-home"),
      VSCode.new(home: "/tmp/no-home"),
      Gemini.new(home: "/tmp/no-home"),
      Goose.new(home: "/tmp/no-home"),
      Copilot.new(home: "/tmp/no-home"),
      OpenCode.new(home: "/tmp/no-home")
    ]

    for provider <- providers do
      assert provider.providers == []
    end
  end
end
