defmodule FastestMCP.Providers.Skill do
  @moduledoc false

  use FastestMCP.Provider

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Providers.Skills.Common
  alias FastestMCP.Providers.Skills.Common.SkillInfo

  defstruct [:skill_info, :main_file_name, supporting_files: :template]

  def new(skill_path, opts \\ []) do
    main_file_name = Keyword.get(opts, :main_file_name, "SKILL.md")

    %__MODULE__{
      skill_info: Common.load_skill!(skill_path, main_file_name),
      main_file_name: main_file_name,
      supporting_files:
        normalize_supporting_files(Keyword.get(opts, :supporting_files, :template))
    }
  end

  @impl FastestMCP.Provider
  def provider_type(%__MODULE__{}), do: "SkillProvider"

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{} = provider, :resource, _operation) do
    resources =
      [
        main_resource(provider),
        manifest_resource(provider)
      ]

    case provider.supporting_files do
      :resources -> resources ++ supporting_file_resources(provider)
      :template -> resources
    end
  end

  def list_components(%__MODULE__{} = provider, :resource_template, _operation) do
    case provider.supporting_files do
      :template -> [supporting_file_template(provider)]
      :resources -> []
    end
  end

  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  defp main_resource(%__MODULE__{skill_info: skill_info, main_file_name: main_file_name}) do
    ComponentCompiler.compile(
      :resource,
      "skill://#{skill_info.name}/#{main_file_name}",
      fn _arguments, _context -> read_file!(skill_info, main_file_name) end,
      description: skill_info.description,
      mime_type: Common.infer_mime_type(main_file_name),
      meta: %{
        "fastestmcp" => %{"skill" => %{"name" => skill_info.name, "is_manifest" => false}}
      }
    )
  end

  defp manifest_resource(%__MODULE__{skill_info: skill_info}) do
    ComponentCompiler.compile(
      :resource,
      "skill://#{skill_info.name}/_manifest",
      fn _arguments, _context -> Common.manifest_json(skill_info) end,
      description: "File listing for #{skill_info.name}",
      mime_type: "application/json",
      meta: %{
        "fastestmcp" => %{"skill" => %{"name" => skill_info.name, "is_manifest" => true}}
      }
    )
  end

  defp supporting_file_resources(%__MODULE__{skill_info: %SkillInfo{} = skill_info}) do
    for file <- skill_info.files,
        file.path != skill_info.main_file,
        do: supporting_file_resource(skill_info, file.path)
  end

  defp supporting_file_resource(%SkillInfo{} = skill_info, relative_path) do
    ComponentCompiler.compile(
      :resource,
      "skill://#{skill_info.name}/#{relative_path}",
      fn _arguments, _context -> read_file!(skill_info, relative_path) end,
      description: "File from #{skill_info.name} skill",
      mime_type: Common.infer_mime_type(relative_path),
      meta: %{"fastestmcp" => %{"skill" => %{"name" => skill_info.name}}}
    )
  end

  defp supporting_file_template(%__MODULE__{skill_info: skill_info}) do
    ComponentCompiler.compile(
      :resource_template,
      "skill://#{skill_info.name}/{path*}",
      fn %{"path" => relative_path}, _context -> read_file!(skill_info, relative_path) end,
      description: "Files from #{skill_info.name}",
      mime_type: "application/octet-stream",
      meta: %{
        "fastestmcp" => %{
          "skill" => %{"name" => skill_info.name},
          "template_name" => "#{skill_info.name}_files"
        }
      }
    )
  end

  defp read_file!(skill_info, relative_path) do
    case Common.safe_file_path(skill_info, relative_path) do
      {:ok, real_path} ->
        File.read!(real_path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: relative_path
    end
  end

  defp normalize_supporting_files(value) when value in [:template, :resources], do: value
  defp normalize_supporting_files("template"), do: :template
  defp normalize_supporting_files("resources"), do: :resources

  defp normalize_supporting_files(other) do
    raise ArgumentError, "unsupported supporting_files mode #{inspect(other)}"
  end
end
