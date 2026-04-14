# Transforms

FastestMCP has two transform layers:

1. server transforms, which rewrite or filter components inside a server
2. provider transforms, which rewrite provider-backed identifiers as they are
   exposed to the parent server

Both exist because composition creates two different needs:

- sometimes you want to change how a server presents its own components
- sometimes you want to mount a provider but rename or namespace what it
  exposes without changing the source

## Server Transforms

Server transforms are added with `FastestMCP.add_transform/2`.

They receive the component plus the current operation and can:

- return the component unchanged
- return a modified component
- return `nil` to filter it out
- mark it disabled so later policy rejects it

```elixir
transform = fn component, _operation ->
  if FastestMCP.Component.identifier(component) == "internal" do
    %{component | enabled: false}
  else
    component
  end
end

server =
  FastestMCP.server("transforms")
  |> FastestMCP.add_transform(transform)
  |> FastestMCP.add_tool("public", fn _args, _ctx -> :ok end)
  |> FastestMCP.add_tool("internal", fn _args, _ctx -> :ok end)
```

This is useful when the filtering rule belongs to the server itself rather than
to a mounted provider.

## Provider Transforms

Provider transforms rewrite provider-backed identifiers while preserving reverse
lookup back to the original component.

FastestMCP exposes them through `FastestMCP.add_provider_transform/2`:

```elixir
provider =
  FastestMCP.Providers.Local.new(name: "dynamic")
  |> FastestMCP.Providers.Local.add_tool("echo", fn arguments, _ctx -> arguments end)
  |> FastestMCP.add_provider_transform(
    FastestMCP.ProviderTransforms.Namespace.new("tools")
  )
```

That lets the mounted provider expose `tools_echo` while still resolving the
backing component correctly.

## Namespacing Mounted Components

The most common provider transform is namespacing.

```elixir
child =
  FastestMCP.server("child")
  |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

parent =
  FastestMCP.server("parent")
  |> FastestMCP.mount(child, namespace: "child")
```

Mounted tools become:

- `child_echo`
- `child_...` for prompts
- namespaced URIs for resources and resource templates

Use namespacing whenever the parent and child may expose overlapping names.

## Tool Renaming

Provider tool transforms can rename provider-backed tools without changing the
source provider:

```elixir
provider =
  FastestMCP.Providers.Local.new(name: "dynamic")
  |> FastestMCP.Providers.Local.add_tool("dynamic_echo", fn arguments, _ctx -> arguments end)
  |> FastestMCP.add_provider_transform(
    FastestMCP.ProviderTransforms.ToolTransform.new(%{
      "dynamic_echo" => %{name: "echo"}
    })
  )
```

Clients now see `echo`, but calls are still mapped back to `dynamic_echo`
behind the scenes.

## Stacking Transforms

Provider transforms can be stacked:

```elixir
provider =
  child
  |> FastestMCP.Providers.MountedServer.new()
  |> FastestMCP.add_provider_transform(
    FastestMCP.ProviderTransforms.Namespace.new("child")
  )
  |> FastestMCP.add_provider_transform(
    FastestMCP.ProviderTransforms.ToolTransform.new(%{
      "child_echo" => %{name: "short"}
    })
  )
```

That pattern is useful when you want collision safety first and a curated public
name second.

## Tool-only Clients

Some FastMCP docs describe tool-search and resource-to-tool transforms.

FastestMCP v0.1 does not ship a public tool-search transform, but it does ship
tool-injection middleware helpers for tool-only clients:

- `FastestMCP.Middleware.prompt_tools/1`
- `FastestMCP.Middleware.resource_tools/1`

Those helpers expose synthetic tools that bridge prompt and resource workflows
through the normal tool surface.

## Transforms vs Middleware

Use transforms when you are shaping component identity.

Use [Middleware](middleware.md) when you are shaping request execution.

In practice:

- namespacing, renaming, filtering: transforms
- logging, retry, caching, rate limiting: middleware

## Why This Shape

FastestMCP separates "what components exist" from "how requests run."

That split keeps composition understandable. Providers and transforms define the
catalog. Middleware defines execution behavior. Mixing those two concerns tends
to make mounted systems much harder to debug.

## Related Guides

- [Providers and Mounting](providers-and-mounting.md)
- [Middleware](middleware.md)
- [Versioning and Visibility](versioning-and-visibility.md)
