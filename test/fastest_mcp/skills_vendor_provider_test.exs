defmodule FastestMCP.SkillsVendorProviderTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Providers.Skills
  alias FastestMCP.Providers.SkillsDirectory

  # Relative roots are under the home directory; earlier roots take precedence.
  @vendor_roots %{
    claude: [".claude/skills"],
    codex: ["/etc/codex/skills", ".codex/skills"],
    copilot: [".copilot/skills"],
    cursor: [".cursor/skills"],
    gemini: [".gemini/skills"],
    goose: [".config/agents/skills"],
    opencode: [".config/opencode/skills"],
    vscode: [".copilot/skills"]
  }

  test "vendor providers use the expected roots and options" do
    home = "/tmp/fake-home"

    for {vendor, roots} <- @vendor_roots do
      provider = Skills.vendor(vendor, home: home)

      assert %SkillsDirectory{reload: false, supporting_files: :template} = provider
      assert provider.roots == Enum.map(roots, &Path.expand(&1, home))
    end

    codex =
      Skills.vendor(:codex,
        home: home,
        system_root: "/opt/codex/skills",
        reload: true,
        supporting_files: :resources
      )

    assert codex.roots == ["/opt/codex/skills", Path.join(home, ".codex/skills")]
    assert codex.reload == true
    assert codex.supporting_files == :resources
    assert codex.main_file_name == "SKILL.md"
  end

  test "vendor providers handle nonexistent roots gracefully" do
    for vendor <- Map.keys(@vendor_roots) do
      provider = Skills.vendor(vendor, home: "/tmp/no-home", system_root: "/tmp/no-home/etc")
      assert provider.providers == []
    end
  end

  test "unknown vendors are rejected" do
    assert_raise ArgumentError, ~r/unknown skills vendor :unknown/, fn ->
      Skills.vendor(:unknown, home: "/tmp/no-home")
    end
  end
end
