defmodule FastestMCP.Provider do
  @moduledoc ~S"""
  Behaviour and runtime wrapper for provider-backed component sources.

  Providers are how a server exposes components that do not live directly on the
  `%FastestMCP.Server{}` struct. Common examples are:

    * mounted servers
    * OpenAPI-backed tools
    * skill-directory resources
    * the live `FastestMCP.ComponentManager`

  ## Writing a provider

  A provider is a struct whose module calls `use FastestMCP.Provider` and
  implements `list_components/3`:

  ```elixir
  defmodule MyApp.CatalogProvider do
    use FastestMCP.Provider

    defstruct tools: []

    @impl FastestMCP.Provider
    def list_components(%__MODULE__{tools: tools}, :tool, _operation), do: tools
    def list_components(%__MODULE__{}, _kind, _operation), do: []
  end
  ```

  These callbacks have overridable defaults:

    * `get_component_candidates/4` and `get_resource_target_candidates/3`
      resolve exact lookups and resource reads from `list_components/3`;
      override them when the source can resolve one identifier or URI without
      listing everything. Candidate callbacks return every matching version.
    * `provider_type/1` is the last segment of the module name.
    * `http_routes/1` and `required_extensions/1` return `[]`.
    * `activate_runtime/1` and `deactivate_runtime/1` run when the owning server
      starts and stops; the defaults keep the provider unchanged.

  `list_component_page/5` defaults to `nil`, which lists the provider with
  `list_components/3`. Implement it to serve bounded, key-ordered pages for wire
  list operations instead of materializing the whole catalog.

  ## Transforms

  A provider can also be wrapped with transforms. Transforms rewrite component
  identifiers on the way out and translate them back on the way in. That is how
  namespacing and tool renaming are applied without changing the underlying
  provider implementation. See `FastestMCP.ProviderTransform`.
  """

  # A leaf module: `use FastestMCP.Provider` is a compile-time dependency, so
  # the functions that call providers live in `FastestMCP.Provider.Dispatch`.

  alias FastestMCP.Operation
  alias FastestMCP.ServerExtension

  defstruct [:inner, transforms: []]

  @type target :: {:exact | :template, struct(), map()}

  @type t :: %__MODULE__{inner: struct(), transforms: [struct()]}

  @callback list_components(struct(), atom(), Operation.t()) :: [struct()]
  @callback get_component_candidates(struct(), atom(), String.t(), Operation.t()) :: [struct()]
  @callback get_resource_target_candidates(struct(), String.t(), Operation.t()) :: [target()]

  @doc """
  Reads one source-level component page, or returns `nil` to be listed with
  `list_components/3` (the default).

  It receives the provider value, component kind, normalized stable after-key,
  requested limit, and current operation, and returns `{:ok, %{items:
  components, next_after: key_or_nil}}` (the outer `{:ok, ...}` may be
  omitted). Components use `FastestMCP.Pagination.default_key/1` ordering. A
  non-nil `next_after` declares that another source page is available. The page
  holds source candidates only; the shared pipeline still owns component
  transforms, visibility, and authorization.

  A provider with transforms is always listed with `list_components/3`, because
  an arbitrary rename can change the ordering.
  """
  @callback list_component_page(struct(), atom(), term(), pos_integer(), Operation.t()) ::
              map() | {:ok, map()} | nil

  @callback provider_type(struct()) :: String.t()
  @callback http_routes(struct()) :: list()
  @callback required_extensions(struct()) :: [ServerExtension.t()]
  @callback activate_runtime(struct()) :: {:ok, struct()} | {:error, term()}
  @callback deactivate_runtime(struct()) :: term()

  defmacro __using__(_opts) do
    provider_type = __CALLER__.module |> Module.split() |> List.last()

    quote do
      @behaviour FastestMCP.Provider

      @doc false
      def get_component_candidates(provider, kind, identifier, operation) do
        provider
        |> list_components(kind, operation)
        |> FastestMCP.Component.Lookup.candidates(identifier, operation.version)
      end

      @doc false
      def get_resource_target_candidates(provider, uri, operation) do
        FastestMCP.Component.Lookup.resource_targets(
          list_components(provider, :resource, operation),
          fn -> list_components(provider, :resource_template, operation) end,
          uri,
          operation.version
        )
      end

      @doc false
      def provider_type(_provider), do: unquote(provider_type)

      @doc false
      def http_routes(_provider), do: []

      @doc false
      def required_extensions(_provider), do: []

      @doc false
      def activate_runtime(provider), do: {:ok, provider}

      @doc false
      def deactivate_runtime(_provider), do: :ok

      @doc false
      def list_component_page(_provider, _kind, _after_key, _limit, _operation), do: nil

      defoverridable FastestMCP.Provider
    end
  end

  @doc "Wraps a provider struct for the runtime; wrapped providers are returned as is."
  def new(%__MODULE__{} = provider), do: provider
  def new(%_{} = provider), do: %__MODULE__{inner: provider}

  @doc "Adds a `FastestMCP.ProviderTransform` to the provider."
  def add_transform(provider, %_{} = transform) do
    provider = new(provider)
    %{provider | transforms: provider.transforms ++ [transform]}
  end
end
