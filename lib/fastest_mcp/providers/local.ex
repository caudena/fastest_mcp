defmodule FastestMCP.Providers.Local do
  require Logger

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
      on_duplicate: normalize_on_duplicate(Keyword.get(opts, :on_duplicate, :error))
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
  def get_component(%__MODULE__{} = provider, component_type, identifier, _operation) do
    provider
    |> list_components(component_type, nil)
    |> Enum.filter(&(Component.identifier(&1) == to_string(identifier)))
    |> Component.highest_version()
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, _operation) do
    exact = get_component(provider, :resource, uri, nil)

    case exact do
      nil ->
        provider.resource_templates
        |> Enum.reduce([], fn template, matches ->
          case ResourceTemplate.match(template, uri) do
            nil -> matches
            captures -> [{template, captures} | matches]
          end
        end)
        |> pick_template()

      component ->
        {:exact, component, %{}}
    end
  end

  defp put_component(%__MODULE__{} = provider, key, component) do
    components = Map.fetch!(provider, key)
    validate_version_mixing!(components, component)

    case duplicate_match(components, component) do
      nil ->
        Map.update!(provider, key, &(&1 ++ [component]))

      _match ->
        apply_duplicate_policy(provider, key, component)
    end
  end

  defp drop_component(%__MODULE__{} = provider, key, identifier) do
    Map.update!(provider, key, fn components ->
      Enum.reject(components, &(Component.identifier(&1) == identifier))
    end)
  end

  defp pick_template([]), do: nil

  defp pick_template(matches) do
    {component, captures} =
      Enum.reduce(matches, nil, fn
        current, nil ->
          current

        {candidate, _} = current, {best, _} = previous ->
          if Component.compare_versions(candidate.version, best.version) == :gt,
            do: current,
            else: previous
      end)

    {:template, component, captures}
  end

  defp validate_version_mixing!(existing_components, component) do
    siblings =
      Enum.filter(existing_components, fn existing ->
        Component.identifier(existing) == Component.identifier(component)
      end)

    has_versioned = Enum.any?(siblings, &(not is_nil(Component.version(&1))))
    has_unversioned = Enum.any?(siblings, &is_nil(Component.version(&1)))
    incoming_unversioned = is_nil(Component.version(component))
    incoming_versioned = not incoming_unversioned

    cond do
      incoming_unversioned and has_versioned ->
        raise ArgumentError,
              "#{Component.type(component)} #{inspect(Component.identifier(component))} cannot mix unversioned and versioned definitions"

      incoming_versioned and has_unversioned ->
        raise ArgumentError,
              "#{Component.type(component)} #{inspect(Component.identifier(component))} cannot mix versioned and unversioned definitions"

      true ->
        :ok
    end
  end

  defp duplicate_match(existing_components, component) do
    Enum.find(existing_components, fn existing ->
      Component.identifier(existing) == Component.identifier(component) and
        Component.version(existing) == Component.version(component)
    end)
  end

  defp apply_duplicate_policy(%__MODULE__{} = provider, key, component) do
    case provider.on_duplicate do
      :error ->
        raise_duplicate_error(component)

      :warn ->
        Logger.warning(duplicate_warning(component))
        replace_duplicate(provider, key, component)

      :replace ->
        replace_duplicate(provider, key, component)

      :ignore ->
        provider
    end
  end

  defp replace_duplicate(%__MODULE__{} = provider, key, component) do
    Map.update!(provider, key, fn components ->
      Enum.map(components, fn existing ->
        if Component.identifier(existing) == Component.identifier(component) and
             Component.version(existing) == Component.version(component) do
          component
        else
          existing
        end
      end)
    end)
  end

  defp raise_duplicate_error(component) do
    if is_nil(Component.version(component)) do
      raise ArgumentError,
            "#{Component.type(component)} #{inspect(Component.identifier(component))} is already defined without a version"
    else
      raise ArgumentError,
            "#{Component.type(component)} #{inspect(Component.identifier(component))} version #{inspect(Component.version(component))} is already defined"
    end
  end

  defp duplicate_warning(component) do
    if is_nil(Component.version(component)) do
      "#{Component.type(component)} #{inspect(Component.identifier(component))} is already defined without a version; replacing existing definition"
    else
      "#{Component.type(component)} #{inspect(Component.identifier(component))} version #{inspect(Component.version(component))} is already defined; replacing existing definition"
    end
  end

  defp normalize_on_duplicate(policy) when policy in [:error, :warn, :ignore, :replace],
    do: policy

  defp normalize_on_duplicate(other) do
    raise ArgumentError,
          "on_duplicate must be one of :error, :warn, :ignore, or :replace, got #{inspect(other)}"
  end
end

require Logger
