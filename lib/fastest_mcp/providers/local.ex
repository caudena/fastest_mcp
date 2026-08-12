defmodule FastestMCP.Providers.Local do
  @moduledoc """
  Standalone in-memory provider for dynamic local components.

  Providers are the extension point FastestMCP uses when components come
  from somewhere other than the server struct itself. This module implements
  one concrete provider shape and is usually wrapped by `FastestMCP.Provider`
  when mounted into a server.

  That lets the runtime treat local, mounted, OpenAPI, and skills-backed
  component sources the same way once they enter the provider layer.

  `on_duplicate:` controls duplicate names inside the provider itself:

    * `:error` - raise
    * `:warn` - log and replace
    * `:ignore` - keep the existing component
    * `:replace` - replace silently
  """

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.ResourceTemplate

  defstruct [
    :name,
    on_duplicate: :error,
    tools: [],
    resources: [],
    resource_templates: [],
    prompts: []
  ]

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    %__MODULE__{
      name: to_string(Keyword.get(opts, :name, "local-provider")),
      on_duplicate:
        Component.normalize_duplicate_policy!(Keyword.get(opts, :on_duplicate, :error))
    }
  end

  @doc "Adds a tool component to the current definition."
  def add_tool(%__MODULE__{} = provider, name, handler, opts \\ []) do
    put_component(
      provider,
      :tools,
      ComponentCompiler.compile(:tool, provider.name, name, handler, opts)
    )
  end

  @doc "Adds a resource component to the current definition."
  def add_resource(%__MODULE__{} = provider, uri, handler, opts \\ []) do
    put_component(
      provider,
      :resources,
      ComponentCompiler.compile(:resource, provider.name, uri, handler, opts)
    )
  end

  @doc "Adds a resource-template component to the current value."
  def add_resource_template(%__MODULE__{} = provider, uri_template, handler, opts \\ []) do
    put_component(
      provider,
      :resource_templates,
      ComponentCompiler.compile(:resource_template, provider.name, uri_template, handler, opts)
    )
  end

  @doc "Adds a prompt component to the current definition."
  def add_prompt(%__MODULE__{} = provider, name, handler, opts \\ []) do
    put_component(
      provider,
      :prompts,
      ComponentCompiler.compile(:prompt, provider.name, name, handler, opts)
    )
  end

  @doc "Removes the named tool."
  def remove_tool(%__MODULE__{} = provider, name),
    do: drop_component(provider, :tools, to_string(name))

  @doc "Removes the resource identified by the given URI."
  def remove_resource(%__MODULE__{} = provider, uri),
    do: drop_component(provider, :resources, to_string(uri))

  @doc "Removes the named resource template."
  def remove_template(%__MODULE__{} = provider, uri_template) do
    drop_component(provider, :resource_templates, to_string(uri_template))
  end

  @doc "Removes the named prompt."
  def remove_prompt(%__MODULE__{} = provider, name),
    do: drop_component(provider, :prompts, to_string(name))

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = provider, :tool, _operation), do: provider.tools
  def list_components(%__MODULE__{} = provider, :resource, _operation), do: provider.resources

  def list_components(%__MODULE__{} = provider, :resource_template, _operation),
    do: provider.resource_templates

  def list_components(%__MODULE__{} = provider, :prompt, _operation), do: provider.prompts
  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = provider, component_type, identifier, operation) do
    provider
    |> get_component_candidates(component_type, identifier, operation)
    |> Component.highest_version()
  end

  @doc false
  def get_component_candidates(%__MODULE__{} = provider, component_type, identifier, operation) do
    provider
    |> list_components(component_type, nil)
    |> Enum.filter(fn component ->
      Component.identifier(component) == to_string(identifier) and
        version_matches?(component, operation_version(operation))
    end)
    |> Component.sort_by_version_desc()
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, operation) do
    provider
    |> get_resource_target_candidates(uri, operation)
    |> pick_resource_target()
  end

  @doc false
  def get_resource_target_candidates(%__MODULE__{} = provider, uri, operation) do
    exact = get_component_candidates(provider, :resource, uri, operation)

    case exact do
      [] ->
        provider.resource_templates
        |> Enum.reduce([], fn template, matches ->
          if version_matches?(template, operation_version(operation)) do
            case ResourceTemplate.match(template, uri) do
              nil -> matches
              captures -> [{:template, template, captures} | matches]
            end
          else
            matches
          end
        end)
        |> Enum.reverse()

      components ->
        Enum.map(components, &{:exact, &1, %{}})
    end
  end

  defp put_component(%__MODULE__{} = provider, key, component) do
    components = Map.fetch!(provider, key)

    case Component.registration_action(components, component, provider.on_duplicate) do
      :insert ->
        Map.replace!(provider, key, components ++ [component])

      {:replace, _existing} ->
        replace_duplicate(provider, key, component)

      {:ignore, _existing} ->
        provider
    end
  end

  defp drop_component(%__MODULE__{} = provider, key, identifier) do
    components =
      provider
      |> Map.fetch!(key)
      |> Enum.reject(&(Component.identifier(&1) == identifier))

    Map.replace!(provider, key, components)
  end

  defp replace_duplicate(%__MODULE__{} = provider, key, component) do
    updated =
      provider
      |> Map.fetch!(key)
      |> Enum.map(fn existing ->
        if Component.identifier(existing) == Component.identifier(component) and
             Component.version(existing) == Component.version(component) do
          component
        else
          existing
        end
      end)

    Map.replace!(provider, key, updated)
  end

  defp pick_resource_target([]), do: nil

  defp pick_resource_target(targets) do
    targets
    |> Component.sort_by_version_desc(fn {_, component, _} -> Component.version(component) end)
    |> List.first()
  end

  defp operation_version(%{version: nil}), do: nil
  defp operation_version(%{version: version}), do: to_string(version)
  defp operation_version(_operation), do: nil

  defp version_matches?(_component, nil), do: true
  defp version_matches?(component, version), do: Component.version(component) == version
end
