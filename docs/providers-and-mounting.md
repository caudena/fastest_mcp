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
Mounting a server into itself is rejected.

Mounted servers enter their own lifespans when the parent runtime starts. Child
handlers receive the mounted server's `ctx.lifespan_context`, and shutdown runs
mounted cleanup before parent cleanup.

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

### Optional application-session tools

FastestMCP ships a small provider for clients that should create and terminate
explicit application sessions themselves:

```elixir
server =
  FastestMCP.server("application")
  |> FastestMCP.add_provider(FastestMCP.Providers.ApplicationSessions.new())
```

It exposes `application_session_create` and
`application_session_terminate`. The provider is never installed
automatically. State reads and writes remain application-specific and use the
`FastestMCP.ApplicationSession` API inside handlers.

## Request-scoped proxy providers

`FastestMCP.Providers.Proxy` exposes an HTTP or stdio MCP server through the
normal provider boundary:

```elixir
proxy =
  FastestMCP.Providers.Proxy.new("https://upstream.example.com/mcp",
    protocol_version: :mirror,
    max_pages: 256,
    max_items: 100_000
  )

server =
  FastestMCP.server("gateway")
  |> FastestMCP.add_provider(proxy)
```

`:mirror` uses the frontend request's exact protocol version. You can instead
pin `"2026-07-28"` or `"2025-11-25"`; `:auto` is intentionally rejected so an
upstream failure cannot trigger a protocol downgrade. Each frontend operation
opens one upstream client, reuses it while resolving and invoking a component,
and closes it when the operation finishes, including error exits. Clients are
not pooled across requests.

The proxy walks upstream tool, prompt, resource, and resource-template catalogs
with bounded pagination. It preserves ordinary content, arbitrary modern
`structuredContent`, resource documents, prompt results, Apps metadata, MRTR
`inputResponses`/`requestState`, and progress. Remote task handles,
subscriptions, notifications, roots mirroring, and callback execution are not
proxied. Unsupported upstream component capabilities appear as empty catalogs.

Proxy providers cannot be combined with bounded ToolSearch. Opaque upstream
cursors cannot prove the absence of a synthetic-name collision without an
unbounded catalog walk, so the server builder rejects that composition before
opening an upstream connection. Use ordinary proxied listing, or expose a
separate locally bounded/searchable provider whose source has a real keyset
page contract.

Incoming credentials are isolated by default. Authorization forwarding is an
explicit HTTP-only deployment choice:

```elixir
FastestMCP.Providers.Proxy.new("https://upstream.example.com/mcp",
  forward_authorization: true,
  trusted_origins: ["https://upstream.example.com"]
)
```

The trusted entry must be the upstream endpoint's exact origin. Only the
incoming `Authorization` header is forwarded, and forwarding cannot be combined
with separately configured upstream OAuth or authorization. Do not enable this
for origins that are not under the same credential trust boundary.
The credential stays outside public request metadata, header snapshots,
request-context snapshots, inspection, and telemetry while the request is live,
and it is cleared before background or detached execution.

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

OpenAPI-backed tools serialize common HTTP request shapes:

- JSON and vendor JSON media types such as `application/problem+json`
- `application/x-www-form-urlencoded`
- `multipart/form-data`
- cookie parameters through the `Cookie` header

Parameter locations are limited to the standard path/query/header/cookie
strings without creating atoms. Operation parameters override path-level
parameters by `{location, name}`; style/explode defaults are applied before
encoding arrays and objects, and path spaces use `%20`. Scalar and array JSON
request bodies are sent directly rather than wrapped. Responses are decoded
only when their media type is JSON or ends in `+json`.

Server URL variables are expanded from their declared defaults when a provider
base URL is derived from the document. Component `$ref` resolution tracks
visited references, so circular schemas are left as references instead of
recursing indefinitely.

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

Skill roots are canonicalized before discovery. A main or supporting file is
rejected if its resolved path leaves the owning root. With `reload: true`, the
runtime activates a metadata-keyed cache and re-reads/re-hashes only files whose
size or modification data changed; unchanged skills reuse their compiled
component representation.

## Custom Providers

When components come from somewhere else entirely, write a custom provider.

At minimum, a provider can implement one or more of:

- `list_components/3`
- `get_component_candidates/4`
- `get_component/4`
- `get_resource_target_candidates/3`
- `get_resource_target/3`
- `http_routes/1`

Candidate callbacks are the preferred exact-lookup interface for versioned
providers. Return every matching version; FastestMCP applies provider transforms
once, then chooses the highest candidate that remains visible and authorized.
Legacy single-result callbacks remain supported and are authoritative, so an
exact lookup does not also enumerate the provider. A provider that implements
only `list_components/3` uses the generic all-version fallback. Implement a
candidate callback whenever an exact lookup must expose multiple versions.

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
