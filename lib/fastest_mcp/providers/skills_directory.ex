defmodule FastestMCP.Providers.SkillsDirectory do
  @moduledoc """
  Provider that scans one or more roots for skill folders.

  Providers are the extension point FastestMCP uses when components come
  from somewhere other than the server struct itself. This module implements
  one concrete provider shape and is usually wrapped by `FastestMCP.Provider`
  when mounted into a server.

  That lets the runtime treat local, mounted, OpenAPI, and skills-backed
  component sources the same way once they enter the provider layer.
  """

  alias FastestMCP.Provider
  alias FastestMCP.Providers.Skill

  defstruct roots: [],
            reload: false,
            main_file_name: "SKILL.md",
            supporting_files: :template,
            providers: []

  @doc "Builds a new value for this module from the supplied options."
  def new(opts) when is_list(opts) do
    roots = normalize_roots(Keyword.get(opts, :roots, []))
    main_file_name = Keyword.get(opts, :main_file_name, "SKILL.md")
    supporting_files = Keyword.get(opts, :supporting_files, :template)
    reload = Keyword.get(opts, :reload, false)

    providers = discover_skills(roots, main_file_name, supporting_files)

    %__MODULE__{
      roots: roots,
      reload: reload,
      main_file_name: main_file_name,
      supporting_files: supporting_files,
      providers: providers
    }
  end

  @doc "Returns the provider type label."
  def provider_type(%__MODULE__{}), do: "SkillsDirectoryProvider"

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = provider, component_type, operation) do
    provider
    |> current_providers()
    |> Enum.flat_map(&Provider.list_components(&1, component_type, operation))
  end

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = provider, component_type, identifier, operation) do
    provider
    |> current_providers()
    |> Enum.find_value(&Provider.get_component(&1, component_type, identifier, operation))
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, operation) do
    provider
    |> current_providers()
    |> Enum.find_value(&Provider.get_resource_target(&1, uri, operation))
  end

  defp current_providers(%__MODULE__{reload: true} = provider) do
    discover_skills(provider.roots, provider.main_file_name, provider.supporting_files)
  end

  defp current_providers(%__MODULE__{} = provider), do: provider.providers

  defp discover_skills(roots, main_file_name, supporting_files) do
    Enum.reduce(roots, {MapSet.new(), []}, fn root, {seen_names, providers} ->
      if File.dir?(root) do
        root
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce({seen_names, providers}, fn entry, {seen, acc} ->
          skill_path = Path.join(root, entry)

          cond do
            not File.dir?(skill_path) ->
              {seen, acc}

            MapSet.member?(seen, entry) ->
              {seen, acc}

            not File.regular?(Path.join(skill_path, main_file_name)) ->
              {seen, acc}

            true ->
              skill_provider =
                Skill.new(skill_path,
                  main_file_name: main_file_name,
                  supporting_files: supporting_files
                )

              {MapSet.put(seen, entry), acc ++ [Provider.new(skill_provider)]}
          end
        end)
      else
        {seen_names, providers}
      end
    end)
    |> elem(1)
  end

  defp normalize_roots(roots) when is_binary(roots), do: [Path.expand(roots)]

  defp normalize_roots(roots) when is_list(roots),
    do: Enum.map(roots, &Path.expand(to_string(&1)))

  defp normalize_roots(root), do: [Path.expand(to_string(root))]
end
