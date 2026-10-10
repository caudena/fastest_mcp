# Transforms

A transform changes how components appear to clients without changing where
they are defined. A server transform is a function that sees every component
of a server, wherever it comes from, and can rewrite or hide it. A provider
transform renames or filters the components of one provider, for example to
give a mounted server a namespace, and sends calls on the new names to the
original components.

```elixir
alias FastestMCP.Components.Tool

hide_internal = fn
  %Tool{} = tool, _operation -> if "internal" in tool.tags, do: nil, else: tool
  component, _operation -> component
end

FastestMCP.server("transforms-hide")
|> FastestMCP.add_transform(hide_internal)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_tool("reindex_notes", fn _args, _ctx -> %{reindexed: true} end,
  tags: ["internal"]
)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("transforms-hide") |> Enum.map(& &1.name)
# => ["search_notes"]
```

## Server transforms

`FastestMCP.add_transform/2` adds a function of a component and the current
`FastestMCP.Operation`. It returns the component, changed or not, or `nil` to
hide it. The component is a struct: `FastestMCP.Components.Tool`,
`FastestMCP.Components.Resource`, `FastestMCP.Components.ResourceTemplate`, or
`FastestMCP.Components.Prompt`, with fields such as `description`, `tags` (a
`MapSet`), `annotations`, `meta`, and `enabled`.

A server transform runs on every component that the server lists or that a
call considers: components of your definition, of providers and mounted
servers, and those that the [component manager](dynamic-components.md) added.
Use it for rules about many components at once:

```elixir
alias FastestMCP.Components.Tool

describe_scope = fn
  %Tool{} = tool, _operation ->
    note = "Only the caller's own notes are used."
    %{tool | description: String.trim("#{tool.description} #{note}")}

  component, _operation ->
    component
end

FastestMCP.server("transforms-describe")
|> FastestMCP.add_transform(describe_scope)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end,
  description: "Find notes by a word or phrase."
)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("transforms-describe") |> Enum.map(& &1.description)
# => ["Find notes by a word or phrase. Only the caller's own notes are used."]
```

The operation describes the request, so a transform can decide per caller:
`operation.context.principal` is the caller's identity. A hidden component
disappears from lists, and an in-process call to it fails with `:filtered`;
an MCP client gets `:not_found`, as for a component that doesn't exist. A
transform can also change a tool's input or output schema: FastestMCP compiles
the new schema and validates calls with it. To decide who
may use a component, though, prefer authorization checks; a transform can add
them to every component, as `FastestMCP.Authorization.transform/2` does (see
[Authorizing components](auth.md#authorizing-components)).

Transforms run in the order you add them, before
[visibility rules](versioning-and-visibility.md) and authorization. A
transform is part of your server definition, so it applies from the first
request and after every restart; visibility rules are switches that you flip
while the server runs.

> #### Don't rename in a server transform {: .warning}
>
> A call finds a component by its original name or URI before server
> transforms run, so a component that a server transform renames is listed
> under the new name but can't be called by it. Rename components with a
> [provider transform](#provider-transforms) instead.

Keep transforms quick and free of side effects: they run for every component
in every list, and again for each call.

## Provider transforms

A provider transform belongs to one provider, such as a
`FastestMCP.Providers.Local`, a proxy, or a mounted server. It renames the
provider's components on the way out, and maps the new names back to the
originals when a client calls them. Add it with
`FastestMCP.add_provider_transform/2` before you add the provider to a
server. FastestMCP includes two:

- `FastestMCP.ProviderTransforms.Namespace` prefixes names: tools and prompts
  become `namespace_name`, and URIs `scheme://namespace/rest`.
- `FastestMCP.ProviderTransforms.ToolTransform` renames tools, from a map of
  the original names to `%{name: new_name}`.

```elixir
alias FastestMCP.ProviderTransforms.Namespace
alias FastestMCP.Providers.Local

archive =
  Local.new()
  |> Local.add_tool("search", fn _args, _ctx -> %{notes: []} end)
  |> Local.add_resource("notes://stats", fn _args, _ctx -> %{archived: 12} end)
  |> FastestMCP.add_provider_transform(Namespace.new("archive"))

FastestMCP.server("transforms-namespace")
|> FastestMCP.add_provider(archive)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("transforms-namespace") |> Enum.map(& &1.name)
# => ["archive_search"]

FastestMCP.list_resources!("transforms-namespace") |> Enum.map(& &1.uri)
# => ["notes://archive/stats"]

FastestMCP.read_resource!("transforms-namespace", "notes://archive/stats")
# => %{archived: 12}
```

The `namespace:` option of `FastestMCP.mount/3` adds a `Namespace` transform.
To combine a namespace with other transforms, build the mounted server's
provider with `FastestMCP.Providers.MountedServer.new/2`, add the transforms,
and add the provider. Transforms apply in the order you add them, so here the
rename sees the namespaced name:

```elixir
alias FastestMCP.ProviderTransforms.{Namespace, ToolTransform}

billing =
  FastestMCP.server("billing")
  |> FastestMCP.add_tool("list_invoices", fn _args, _ctx -> %{invoices: []} end)
  |> FastestMCP.add_tool("refund_invoice", fn _args, _ctx -> %{refunded: true} end,
    tags: ["internal"]
  )

billing_provider =
  billing
  |> FastestMCP.Providers.MountedServer.new(exclude_tags: ["internal"])
  |> FastestMCP.add_provider_transform(Namespace.new("billing"))
  |> FastestMCP.add_provider_transform(
    ToolTransform.new(%{"billing_list_invoices" => %{name: "invoices"}})
  )

FastestMCP.server("transforms-stacked")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_provider(billing_provider)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("transforms-stacked") |> Enum.map(& &1.name)
# => ["invoices", "search_notes"]

FastestMCP.call_tool!("transforms-stacked", "invoices")
# => %{invoices: []}
```

Only the new names reach the components: a call of `list_invoices` or
`billing_list_invoices` fails with `:not_found`.

## Custom provider transforms

A provider transform is a struct whose module calls
`use FastestMCP.ProviderTransform` and overrides one or both callbacks:

- `c:FastestMCP.ProviderTransform.transform_component/3` returns the
  component as the provider offers it, or `nil` to drop it;
- `c:FastestMCP.ProviderTransform.reverse_identifier/4` maps a name or URI
  that a client uses back to the provider's own, with `{:ok, original}`, or
  returns `:error` when it can't belong to the provider.

The defaults leave components and names unchanged. Override
`reverse_identifier/4` whenever `transform_component/3` changes names. This
transform prefixes the names of a provider's tools:

```elixir
# lib/my_app/tool_prefix.ex
defmodule MyApp.ToolPrefix do
  use FastestMCP.ProviderTransform

  alias FastestMCP.Components.Tool

  defstruct [:prefix]

  @impl FastestMCP.ProviderTransform
  def transform_component(%__MODULE__{prefix: prefix}, %Tool{} = tool, _operation),
    do: %{tool | name: prefix <> tool.name}

  def transform_component(%__MODULE__{}, component, _operation), do: component

  @impl FastestMCP.ProviderTransform
  def reverse_identifier(%__MODULE__{prefix: prefix}, :tool, name, _operation) do
    if String.starts_with?(name, prefix),
      do: {:ok, String.replace_prefix(name, prefix, "")},
      else: :error
  end

  def reverse_identifier(%__MODULE__{}, _kind, identifier, _operation), do: {:ok, identifier}
end
```

```elixir
github =
  FastestMCP.Providers.Local.new()
  |> FastestMCP.Providers.Local.add_tool("list_issues", fn _args, _ctx -> %{issues: []} end)
  |> FastestMCP.add_provider_transform(%MyApp.ToolPrefix{prefix: "gh_"})

FastestMCP.server("transforms-custom")
|> FastestMCP.add_provider(github)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("transforms-custom") |> Enum.map(& &1.name)
# => ["gh_list_issues"]

FastestMCP.call_tool!("transforms-custom", "gh_list_issues")
# => %{issues: []}
```

Returning `:error` tells FastestMCP that a name can't come from this provider,
so it doesn't ask the provider at all.

## Details

### How transforms apply

For a list, each provider's components go through its provider transforms, in
the order you added them, then every component goes through the server
transforms, the [visibility rules](versioning-and-visibility.md#the-order-of-rules),
and authorization. For a call, FastestMCP maps the name back through the
provider transforms in reverse order, asks the provider for the original name,
sends what it finds forward through the transforms again, and keeps the
components whose new name matches the one called.

A component that a provider transform drops is unknown to callers, so a call
fails with `:not_found`; one that a server transform hides fails with
`:filtered` in process, and with `:not_found` over MCP. A mounted server's own
transforms apply to its components first, under their original names, before
the mount's provider transforms. When a transform of any kind changes a tool's
input or output schema, FastestMCP compiles the new schema, once for each
distinct schema, and validates calls with it. A provider with provider
transforms, or any provider on a server with server transforms, is listed
whole rather than a page at a time.

### The included transforms

- `FastestMCP.ProviderTransforms.Namespace.new/1` with a blank namespace
  leaves names unchanged. A URI without `://` becomes `namespace/uri`. A name
  without the prefix can't reach the provider. A namespace takes the
  characters of a tool name, letters, digits, `_`, `-`, and `.`, so that
  namespaced names stay valid; another character raises `ArgumentError`.
- A tool name that the transforms of a provider make longer than MCP's 128
  characters raises `ArgumentError` naming the tool: when `mount/3` namespaces
  a tool of the mounted definition, and otherwise when a list or call builds
  the name, which then fails. A later rename to a shorter name avoids it, and a
  name that the provider already gave longer, as a proxied tool's may be,
  stays as it is.
- `FastestMCP.ProviderTransforms.ToolTransform.new/1` renames tools only. A
  mapping without `:name`, a new name that isn't a valid tool name (see
  [Defining a tool](tools.md#defining-a-tool)), or two tools renamed to the
  same name, raises `ArgumentError`. A tool that the map doesn't name keeps
  its name.

## See also

- [Providers and Mounting](providers-and-mounting.md): where provider
  components come from
- [Versioning and Visibility](versioning-and-visibility.md): hiding components
  while the server runs
- [Authentication and Authorization](auth.md): deciding who may use a
  component
- [Middleware](middleware.md): changing requests rather than components
- [Bounded tool search](tools.md#bounded-tool-search): a short tool list for
  a large catalog
- `FastestMCP.ProviderTransform`
