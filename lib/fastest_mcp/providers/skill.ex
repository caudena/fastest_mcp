defmodule FastestMCP.Providers.Skill do
  @moduledoc """
  Provider that exposes a single skill directory as MCP resources.

  Providers are the extension point FastestMCP uses when components come
  from somewhere other than the server struct itself. This module implements
  one concrete provider shape and is usually wrapped by `FastestMCP.Provider`
  when mounted into a server.

  That lets the runtime treat local, mounted, OpenAPI, and skills-backed
  component sources the same way once they enter the provider layer.
  """

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Providers.Skills.Common
  alias FastestMCP.Providers.Skills.Common.SkillInfo

  defstruct [:skill_info, :main_file_name, supporting_files: :template]

  @doc "Builds a new value for this module from the supplied options."
  def new(skill_path, opts \\ []) do
    main_file_name = Keyword.get(opts, :main_file_name, "SKILL.md")

    %__MODULE__{
      skill_info: Common.load_skill!(skill_path, main_file_name),
      main_file_name: main_file_name,
      supporting_files:
        normalize_supporting_files(Keyword.get(opts, :supporting_files, :template))
    }
  end

  @doc "Returns the provider type label."
  def provider_type(%__MODULE__{}), do: "SkillProvider"

  @doc "Lists the components exposed by this module."
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

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = provider, :resource, identifier, _operation) do
    provider
    |> list_components(:resource, nil)
    |> Enum.filter(&(Component.identifier(&1) == to_string(identifier)))
    |> Component.highest_version()
  end

  def get_component(%__MODULE__{} = provider, :resource_template, identifier, _operation) do
    provider
    |> list_components(:resource_template, nil)
    |> Enum.filter(&(Component.identifier(&1) == to_string(identifier)))
    |> Component.highest_version()
  end

  def get_component(%__MODULE__{}, _component_type, _identifier, _operation), do: nil

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, _operation) do
    case parse_skill_uri(uri) do
      {:ok, skill_name, "_manifest"} when skill_name == provider.skill_info.name ->
        {:exact, manifest_resource(provider), %{}}

      {:ok, skill_name, file_path}
      when skill_name == provider.skill_info.name and file_path == provider.main_file_name ->
        {:exact, main_resource(provider), %{}}

      {:ok, skill_name, file_path} when skill_name == provider.skill_info.name ->
        supporting_file_target(provider, file_path)

      _ ->
        nil
    end
  end

  defp main_resource(%__MODULE__{skill_info: skill_info, main_file_name: main_file_name}) do
    ComponentCompiler.compile(
      :resource,
      skill_info.name,
      "skill://#{skill_info.name}/#{main_file_name}",
      fn _arguments, _context ->
        File.read!(Path.join(skill_info.path, main_file_name))
      end,
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
      skill_info.name,
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
    skill_info.files
    |> Enum.reject(&(&1.path == skill_info.main_file))
    |> Enum.map(fn file ->
      supporting_file_resource(skill_info, file.path)
    end)
  end

  defp supporting_file_resource(%SkillInfo{} = skill_info, relative_path) do
    ComponentCompiler.compile(
      :resource,
      skill_info.name,
      "skill://#{skill_info.name}/#{relative_path}",
      fn _arguments, _context ->
        case Common.safe_file_path(skill_info, relative_path) do
          {:ok, real_path} ->
            read_file_content(real_path, relative_path)

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read file", path: relative_path
        end
      end,
      description: "File from #{skill_info.name} skill",
      mime_type: Common.infer_mime_type(relative_path),
      meta: %{"fastestmcp" => %{"skill" => %{"name" => skill_info.name}}}
    )
  end

  defp supporting_file_template(%__MODULE__{skill_info: skill_info}) do
    ComponentCompiler.compile(
      :resource_template,
      skill_info.name,
      "skill://#{skill_info.name}/{path*}",
      fn %{"path" => relative_path}, _context ->
        case Common.safe_file_path(skill_info, relative_path) do
          {:ok, real_path} ->
            read_file_content(real_path, relative_path)

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read file", path: relative_path
        end
      end,
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

  defp supporting_file_target(%__MODULE__{supporting_files: :resources} = provider, file_path) do
    case Common.safe_file_path(provider.skill_info, file_path) do
      {:ok, real_path} ->
        relative_path = Common.relative_file_path(provider.skill_info, real_path)
        {:exact, supporting_file_resource(provider.skill_info, relative_path), %{}}

      {:error, _reason} ->
        nil
    end
  end

  defp supporting_file_target(%__MODULE__{supporting_files: :template} = provider, file_path) do
    case Common.safe_file_path(provider.skill_info, file_path) do
      {:ok, real_path} ->
        relative_path = Common.relative_file_path(provider.skill_info, real_path)
        {:template, supporting_file_template(provider), %{"path" => relative_path}}

      {:error, _reason} ->
        nil
    end
  end

  defp parse_skill_uri("skill://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [skill_name, file_path] -> {:ok, skill_name, file_path}
      _ -> :error
    end
  end

  defp parse_skill_uri(_uri), do: :error

  defp read_file_content(real_path, relative_path) do
    case Common.infer_mime_type(relative_path) do
      "application/octet-stream" -> File.read!(real_path)
      <<"text/", _::binary>> -> File.read!(real_path)
      _ -> File.read!(real_path)
    end
  end

  defp normalize_supporting_files(value) when value in [:template, :resources], do: value
  defp normalize_supporting_files("template"), do: :template
  defp normalize_supporting_files("resources"), do: :resources

  defp normalize_supporting_files(other) do
    raise ArgumentError, "unsupported supporting_files mode #{inspect(other)}"
  end
end
