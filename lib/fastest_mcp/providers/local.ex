defmodule FastestMCP.Providers.Local do
  @moduledoc """
  A provider that holds components built in code, outside a server definition.

  Add it to a server with `FastestMCP.add_provider/2`, optionally after
  `FastestMCP.add_provider_transform/2`:

      provider =
        FastestMCP.Providers.Local.new(name: "dynamic")
        |> FastestMCP.Providers.Local.add_tool("echo", fn arguments, _ctx -> arguments end)

      FastestMCP.server("app") |> FastestMCP.add_provider(provider)

  The `add_*` functions take the same handler and options as the server's
  (see "Component Options" in `FastestMCP.Server`).
  """

  use FastestMCP.Provider

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.ComponentStore

  defstruct [
    :name,
    on_duplicate: :error,
    tools: [],
    resources: [],
    resource_templates: [],
    prompts: []
  ]

  @doc """
  Builds an empty provider. Options: `:name` (default `"local-provider"`) and
  `:on_duplicate` (`:error`, the default, `:warn`, `:ignore`, or `:replace`),
  applied when a component with the same identifier and version is added.
  """
  def new(opts \\ []) do
    %__MODULE__{
      name: to_string(Keyword.get(opts, :name, "local-provider")),
      on_duplicate: ComponentStore.policy!(Keyword.get(opts, :on_duplicate, :error))
    }
  end

  @doc "Adds a tool, as `FastestMCP.add_tool/4` does."
  def add_tool(%__MODULE__{} = provider, name, handler, opts \\ []),
    do: add_component(provider, :tool, name, handler, opts)

  @doc "Adds a resource, as `FastestMCP.add_resource/4` does."
  def add_resource(%__MODULE__{} = provider, uri, handler, opts \\ []),
    do: add_component(provider, :resource, uri, handler, opts)

  @doc "Adds a resource template, as `FastestMCP.add_resource_template/4` does."
  def add_resource_template(%__MODULE__{} = provider, uri_template, handler, opts \\ []),
    do: add_component(provider, :resource_template, uri_template, handler, opts)

  @doc "Adds a prompt, as `FastestMCP.add_prompt/4` does."
  def add_prompt(%__MODULE__{} = provider, name, handler, opts \\ []),
    do: add_component(provider, :prompt, name, handler, opts)

  @doc "Removes every version of the tool `name`."
  def remove_tool(%__MODULE__{} = provider, name), do: drop_component(provider, :tool, name)

  @doc "Removes every version of the resource at `uri`."
  def remove_resource(%__MODULE__{} = provider, uri), do: drop_component(provider, :resource, uri)

  @doc "Removes every version of the resource template `uri_template`."
  def remove_template(%__MODULE__{} = provider, uri_template),
    do: drop_component(provider, :resource_template, uri_template)

  @doc "Removes every version of the prompt `name`."
  def remove_prompt(%__MODULE__{} = provider, name), do: drop_component(provider, :prompt, name)

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{} = provider, kind, _operation),
    do: ComponentStore.list(provider, kind)

  defp add_component(%__MODULE__{} = provider, kind, identifier, handler, opts) do
    component = ComponentCompiler.compile(kind, identifier, handler, opts)

    case ComponentStore.put(provider, component, provider.on_duplicate) do
      {:ok, provider} -> provider
      {:ignore, _existing} -> provider
      {:error, error} -> raise error
    end
  end

  defp drop_component(%__MODULE__{} = provider, kind, identifier) do
    {_removed, provider} = ComponentStore.delete(provider, kind, to_string(identifier), nil)
    provider
  end
end
