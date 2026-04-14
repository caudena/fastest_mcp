defmodule FastestMCP.SkillProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Providers.Skill
  alias FastestMCP.Providers.Skills.Common
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "parse_frontmatter handles basic maps and lists" do
    content = """
    ---
    description: A test skill
    version: "1.0.0"
    tags: [one, "two", 'three']
    ---

    # My Skill
    """

    {frontmatter, body} = Common.parse_frontmatter(content)

    assert frontmatter["description"] == "A test skill"
    assert frontmatter["version"] == "1.0.0"
    assert frontmatter["tags"] == ["one", "two", "three"]
    assert String.contains?(body, "# My Skill")
  end

  test "single skill exposes main file, manifest, supporting files, and metadata" do
    skill_dir = create_skill_dir("my-skill")

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      description: A test skill
      ---

      # My Skill
      """
    )

    File.write!(Path.join(skill_dir, "reference.md"), "# Reference\n\nExtra docs.")
    File.mkdir_p!(Path.join(skill_dir, "scripts"))
    File.write!(Path.join(skill_dir, "scripts/helper.py"), "print('helper')")

    provider = Skill.new(skill_dir)
    server_name = unique_server_name("skill-provider")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    resources = FastestMCP.list_resources(server_name)
    templates = FastestMCP.list_resource_templates(server_name)

    assert length(resources) == 2

    assert Enum.map(resources, & &1.uri) == [
             "skill://my-skill/SKILL.md",
             "skill://my-skill/_manifest"
           ]

    assert [%{uri_template: "skill://my-skill/{path*}"}] = templates

    main_resource = Enum.find(resources, &(&1.uri == "skill://my-skill/SKILL.md"))
    manifest_resource = Enum.find(resources, &(&1.uri == "skill://my-skill/_manifest"))

    assert main_resource.description == "A test skill"

    assert main_resource.meta["fastestmcp"]["skill"] == %{
             "name" => "my-skill",
             "is_manifest" => false
           }

    assert manifest_resource.meta["fastestmcp"]["skill"] == %{
             "name" => "my-skill",
             "is_manifest" => true
           }

    assert %{resources: transport_resources} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })

    transport_main =
      Enum.find(transport_resources, &(&1["uri"] == "skill://my-skill/SKILL.md"))

    assert transport_main["_meta"]["fastestmcp"]["skill"] == %{
             "name" => "my-skill",
             "is_manifest" => false
           }

    assert String.contains?(
             FastestMCP.read_resource(server_name, "skill://my-skill/SKILL.md"),
             "# My Skill"
           )

    assert String.contains?(
             FastestMCP.read_resource(server_name, "skill://my-skill/reference.md"),
             "# Reference"
           )

    assert String.contains?(
             FastestMCP.read_resource(server_name, "skill://my-skill/scripts/helper.py"),
             "helper"
           )

    manifest = Jason.decode!(FastestMCP.read_resource(server_name, "skill://my-skill/_manifest"))
    paths = MapSet.new(Enum.map(manifest["files"], & &1["path"]))

    assert manifest["skill"] == "my-skill"
    assert paths == MapSet.new(["SKILL.md", "reference.md", "scripts/helper.py"])
    assert Enum.all?(manifest["files"], &String.starts_with?(&1["hash"], "sha256:"))
  end

  test "supporting files can be listed as resources and path escapes are blocked" do
    skill_dir = create_skill_dir("resource-mode-skill")

    File.write!(Path.join(skill_dir, "SKILL.md"), "# Resource Mode")
    File.write!(Path.join(skill_dir, "reference.md"), "# Reference")

    secret_file = Path.join(Path.dirname(skill_dir), "secret.txt")
    File.write!(secret_file, "SECRET DATA")
    File.ln_s!(secret_file, Path.join(skill_dir, "leak.txt"))

    provider = Skill.new(skill_dir, supporting_files: :resources)
    server_name = unique_server_name("skill-provider-resources")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    resources = FastestMCP.list_resources(server_name)

    assert length(resources) == 3
    assert Enum.any?(resources, &(&1.uri == "skill://resource-mode-skill/reference.md"))
    refute Enum.any?(resources, &(&1.uri == "skill://resource-mode-skill/leak.txt"))
    assert [] == FastestMCP.list_resource_templates(server_name)

    assert "# Reference" ==
             FastestMCP.read_resource(server_name, "skill://resource-mode-skill/reference.md")

    assert_raise FastestMCP.Error, fn ->
      FastestMCP.read_resource(server_name, "skill://resource-mode-skill/../../../secret.txt")
    end
  end

  test "skill metadata survives mounted providers" do
    skill_dir = create_skill_dir("mounted-skill")
    File.write!(Path.join(skill_dir, "SKILL.md"), "# Mounted Skill")

    child =
      FastestMCP.server("child-skill-server")
      |> FastestMCP.add_provider(Skill.new(skill_dir))

    parent_name = unique_server_name("mounted-skill-parent")

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "skills")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    resources = FastestMCP.list_resources(parent_name)
    main = Enum.find(resources, &(&1.uri == "skill://skills/mounted-skill/SKILL.md"))

    assert main.meta["fastestmcp"]["skill"] == %{
             "name" => "mounted-skill",
             "is_manifest" => false
           }

    assert "# Mounted Skill" ==
             FastestMCP.read_resource(parent_name, "skill://skills/mounted-skill/SKILL.md")
  end

  defp create_skill_dir(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "fastest_mcp_skill_provider_#{System.unique_integer([:positive])}"
      )

    skill_dir = Path.join(root, name)
    File.mkdir_p!(skill_dir)
    on_exit(fn -> File.rm_rf(root) end)
    skill_dir
  end

  defp unique_server_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
