# Providers and Mounting

Providers let FastestMCP expose components that do not live directly on the
base server struct.

This is the composition layer of the runtime. It is how one server can present
components from:

- mounted FastestMCP servers
- standalone local providers
- OpenAPI-generated tool catalogs
- skill directories
- custom dynamic sources

## Why Providers Exist

Without providers, every component would need to be copied onto the base server
definition before startup. That works for small static servers, but it is not a
good fit for mounted runtimes, generated tool catalogs, or dynamic external
component sources.

Providers let FastestMCP keep one runtime and one execution pipeline while
sourcing components from multiple places.

## Mounted Servers

The simplest composition pattern is mounting one FastestMCP server into
another:

```elixir
child =
  FastestMCP.server("child")
  |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

parent =
  FastestMCP.server("parent")
  |> FastestMCP.mount(child, namespace: "child")
```

Mounted components participate in normal:

- list operations
- tool calls
- resource reads
- prompt rendering

Use `namespace:` whenever the child may overlap with parent component names.

## Mount Filtering

Mounted servers can be filtered by tags:

```elixir
parent =
  FastestMCP.server("parent")
  |> FastestMCP.mount(child, include_tags: ["allowed"])
```

Or:

```elixir
parent =
  FastestMCP.server("parent")
  |> FastestMCP.mount(child, exclude_tags: ["blocked"])
```

This is useful when a child server is large but the parent should only surface
part of it.

## Standalone Local Providers

FastestMCP also ships an explicit local provider module for dynamic composition
without creating a separate server:

```elixir
provider =
  FastestMCP.Providers.Local.new(name: "dynamic")
  |> FastestMCP.Providers.Local.add_tool("dynamic.echo", fn arguments, _ctx -> arguments end)

server =
  FastestMCP.server("providers")
  |> FastestMCP.add_provider(provider)
```

Use this when you want provider behavior, but your source is still local
Elixir code.

## OpenAPI-backed Providers

OpenAPI support is the fastest way to turn an existing HTTP API into a tool
catalog:

```elixir
server =
  FastestMCP.from_openapi(openapi_spec,
    name: "petstore",
    base_url: "https://api.example.com"
  )

{:ok, _pid} = FastestMCP.start_server(server)
FastestMCP.list_tools("petstore")
```

Under the hood, FastestMCP maps OpenAPI operations to tools, builds schemas
from parameters and request bodies, and routes calls through its shared HTTP
helper.

## Skills Providers

FastestMCP can expose skill directories as MCP resources:

```elixir
provider =
  FastestMCP.Providers.SkillsDirectory.new(
    roots: ["~/.claude/skills", "~/.codex/skills"],
    reload: false
  )

server =
  FastestMCP.server("skills")
  |> FastestMCP.add_provider(provider)
```

This is useful when you want local skills to become discoverable through MCP
resource reads without hand-registering each file.

## Custom Providers

When components come from somewhere else entirely, write a custom provider.

At minimum, a provider can implement one or more of:

- `list_components/3`
- `get_component/4`
- `get_resource_target/3`
- `http_routes/1`

Example:

```elixir
defmodule MyApp.CountingProvider do
  defstruct [:tool]

  def list_components(%__MODULE__{tool: tool}, :tool, _operation), do: [tool]
  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  def get_component(%__MODULE__{tool: tool}, :tool, "dynamic_echo", _operation), do: tool
  def get_component(%__MODULE__{}, _component_type, _identifier, _operation), do: nil
end
```

Then:

```elixir
server =
  FastestMCP.server("providers")
  |> FastestMCP.add_provider(%MyApp.CountingProvider{tool: my_tool})
```

Use a custom provider when your components come from a database, config store,
external service, or plugin system.

## Provider Transforms

Provider-backed components can be reshaped without changing the source:

- namespacing
- tool renaming
- stacked provider transforms

See [Transforms](transforms.md) for the detailed patterns.

## What FastestMCP Does Not Ship Yet

The FastMCP docs cover filesystem and proxy providers.

FastestMCP v0.1 does not yet expose those as public built-ins. The current
provider surface focuses on:

- mounted FastestMCP servers
- explicit local providers
- OpenAPI-backed providers
- skills providers
- custom provider implementations

That keeps the first release focused on the provider shapes already exercised by
the runtime and test suite.

## Why This Shape

Providers let FastestMCP keep one runtime while sourcing components from many
places.

Mounted servers, OpenAPI catalogs, skill directories, and dynamic custom
sources all still feed the same operation pipeline. That is the key property:
composition without inventing a second execution model.

## Related Guides

- [Transforms](transforms.md)
- [Components](components.md)
- [Versioning and Visibility](versioning-and-visibility.md)
