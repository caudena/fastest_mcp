defmodule FastestMCP.SkillsDirectoryProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Providers.Skills
  alias FastestMCP.Providers.SkillsDirectory

  test "directory provider discovers skills, descriptions, templates, and nested files" do
    skills_root = create_skills_root("skills")

    simple_dir = Path.join(skills_root, "simple-skill")
    File.mkdir_p!(simple_dir)

    File.write!(
      Path.join(simple_dir, "SKILL.md"),
      """
      ---
      description: A simple test skill
      ---
      # Simple Skill
      """
    )

    complex_dir = Path.join(skills_root, "complex-skill")
    File.mkdir_p!(Path.join(complex_dir, "scripts"))

    File.write!(
      Path.join(complex_dir, "SKILL.md"),
      """
      # Complex Skill

      See [reference](reference.md) for more details.
      """
    )

    File.write!(Path.join(complex_dir, "reference.md"), "# Reference")
    File.write!(Path.join(complex_dir, "scripts/helper.py"), "print('Hello from helper')")

    provider = SkillsDirectory.new(roots: skills_root)
    server_name = unique_server_name("skills-directory")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    resources = FastestMCP.list_resources(server_name)
    templates = FastestMCP.list_resource_templates(server_name)

    assert length(resources) == 4
    assert length(templates) == 2

    simple_main = Enum.find(resources, &(&1.uri == "skill://simple-skill/SKILL.md"))
    complex_main = Enum.find(resources, &(&1.uri == "skill://complex-skill/SKILL.md"))

    assert simple_main.description == "A simple test skill"
    assert complex_main.description == "Complex Skill"

    assert String.contains?(
             FastestMCP.read_resource(server_name, "skill://complex-skill/scripts/helper.py"),
             "Hello from helper"
           )

    assert String.contains?(
             FastestMCP.read_resource(server_name, "skill://complex-skill/reference.md"),
             "# Reference"
           )
  end

  test "reload mode picks up new skills and duplicate names prefer the first root" do
    root1 = create_skills_root("skills-root-1")
    root2 = create_skills_root("skills-root-2")

    duplicate1 = Path.join(root1, "duplicate-skill")
    File.mkdir_p!(duplicate1)

    File.write!(
      Path.join(duplicate1, "SKILL.md"),
      "---\ndescription: First occurrence\n---\n# First"
    )

    duplicate2 = Path.join(root2, "duplicate-skill")
    File.mkdir_p!(duplicate2)

    File.write!(
      Path.join(duplicate2, "SKILL.md"),
      "---\ndescription: Second occurrence\n---\n# Second"
    )

    provider = SkillsDirectory.new(roots: [root1, root2], reload: true)
    server_name = unique_server_name("skills-directory-reload")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    initial_resources = FastestMCP.list_resources(server_name)
    main = Enum.find(initial_resources, &(&1.uri == "skill://duplicate-skill/SKILL.md"))
    assert main.description == "First occurrence"

    new_skill = Path.join(root1, "new-skill")
    File.mkdir_p!(new_skill)
    File.write!(Path.join(new_skill, "SKILL.md"), "---\ndescription: New skill\n---\n# New")

    reloaded_resources = FastestMCP.list_resources(server_name)
    assert Enum.any?(reloaded_resources, &(&1.uri == "skill://new-skill/SKILL.md"))
  end

  test "supporting files can be listed as resources and Skills alias delegates to directory provider" do
    skills_root = create_skills_root("skills-resources")
    complex_dir = Path.join(skills_root, "complex-skill")
    File.mkdir_p!(Path.join(complex_dir, "scripts"))
    File.write!(Path.join(complex_dir, "SKILL.md"), "# Complex Skill")
    File.write!(Path.join(complex_dir, "reference.md"), "# Reference")
    File.write!(Path.join(complex_dir, "scripts/helper.py"), "print('Hello')")

    provider = Skills.new(roots: skills_root, supporting_files: :resources)
    server_name = unique_server_name("skills-directory-resources")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    resources = FastestMCP.list_resources(server_name)

    assert length(resources) == 4
    assert Enum.any?(resources, &(&1.uri == "skill://complex-skill/reference.md"))
    assert Enum.any?(resources, &(&1.uri == "skill://complex-skill/scripts/helper.py"))
    assert [] == FastestMCP.list_resource_templates(server_name)
  end

  defp create_skills_root(name) do
    root =
      Path.join(System.tmp_dir!(), "fastest_mcp_#{name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp unique_server_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
