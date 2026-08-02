# FastestMCP

FastestMCP is a BEAM-native MCP toolkit for Elixir.

It includes MCP tools, resources, prompts, middleware, auth, providers,
background tasks, and streamable HTTP. FastestMCP is built as an OTP system
with supervised runtime trees, explicit request, session, and task lifetimes,
and module-first server startup that fits normal Elixir applications.

## Installation

Add FastestMCP to your dependencies:

```elixir
def deps do
  [
    {:fastest_mcp, "~> 0.2.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

### Upgrading from 0.1.x

FastestMCP 0.2.0 has one protocol boundary: MCP `2025-11-25` over JSON-RPC
2.0. Streamable HTTP accepts one message per POST at `/mcp`; legacy
method-specific routes and JSON-RPC batches are gone. Stateful clients must use
the server-issued session id and complete the initialize lifecycle. Stateless
HTTP is POST-only and has no sessions, subscriptions, or task augmentation.

Remote task augmentation is standard `tools/call` only. Local Elixir prompt and
resource tasks remain available, as does local `FastestMCP.send_task_input/5`,
but the remote prompt/resource task extensions and wire `tasks/sendInput` method
were removed. See the [0.2.0 changelog](CHANGELOG.md#020---2026-08-02) and
[transport migration notes](docs/transports.md#migrating-from-01) for the full
checklist.

## Quick Start

Start with a module-owned server:

```elixir
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule,
    http: [port: 4100, allowed_hosts: :localhost]

  alias FastestMCP.Context

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
    |> FastestMCP.add_tool("visit", fn _arguments, ctx ->
      visits = Context.get_state(ctx, :visits, 0) + 1
      :ok = Context.set_state(ctx, :visits, visits)
      %{visits: visits, server: ctx.server_name}
    end)
  end
end

children = [
  MyApp.MCPServer
]

FastestMCP.call_tool(MyApp.MCPServer, "sum", %{"a" => 20, "b" => 22})
# => 42
```

The full onboarding path, including transport startup and the first connected
client call, lives in [docs/onboarding.md](docs/onboarding.md).

## Guides

- [Onboarding](docs/onboarding.md)
- [Why FastestMCP](docs/why-fastest-mcp.md)
- [Components](docs/components.md)
- [Tools](docs/tools.md)
- [Resources](docs/resources.md)
- [Prompts](docs/prompts.md)
- [Context](docs/context.md)
- [Dependency Injection](docs/dependency-injection.md)
- [Lifespan](docs/lifespan.md)
- [Transports](docs/transports.md)
- [Client](docs/client.md)
- [Sampling and Interaction](docs/sampling-and-interaction.md)
- [Pagination](docs/pagination.md)
- [Progress](docs/progress.md)
- [Logging](docs/logging.md)
- [Telemetry](docs/telemetry.md)
- [Dynamic Component Manager](docs/component-manager.md)
- [Auth](docs/auth.md)
- [Middleware](docs/middleware.md)
- [Background Tasks](docs/background-tasks.md)
- [Providers and Mounting](docs/providers-and-mounting.md)
- [Transforms](docs/transforms.md)
- [Versioning and Visibility](docs/versioning-and-visibility.md)
- [Testing](docs/testing.md)
- [Runtime State and Storage](docs/runtime-state-and-storage.md)
- [Compatibility and Scope](docs/compatibility-and-scope.md)

## Public API

FastestMCP keeps the public surface deliberately curated.

- `FastestMCP`: top-level server, transport, runtime, and task helpers
- `FastestMCP.ServerModule`: preferred module-owned startup wrapper
- `FastestMCP.Server`: low-level server definition for dynamic cases
- `FastestMCP.Context`: explicit request, session, auth, and task context
- `FastestMCP.RequestContext`: stable request snapshot derived from context
- `FastestMCP.Client`: connected MCP client for streamable HTTP and stdio
- `FastestMCP.Auth`: auth contract and shared authenticator wrapper
- `FastestMCP.Auth.Result`: normalized authenticator result
- `FastestMCP.Auth.StaticToken`: hermetic bearer-token authenticator
- `FastestMCP.Middleware`: built-in middleware constructors
- `FastestMCP.Provider`: provider contract for mounted and dynamic surfaces
- `FastestMCP.ComponentManager`: runtime mutation for live servers
- `FastestMCP.Sampling`: Elixir-friendly sampling helpers
- `FastestMCP.Interact`: higher-level elicitation helpers
- `FastestMCP.SessionStateStore` and `FastestMCP.SessionStateStore.Memory`:
  session-state backend contract and default backend
- `FastestMCP.TaskBackend` and `FastestMCP.TaskBackend.Memory`: background-task
  storage contract and default ETS-backed backend
- `FastestMCP.Tools.Result`: explicit tool result helper type
- `FastestMCP.Prompts.Message` and `FastestMCP.Prompts.Result`: explicit prompt
  helper types
- `FastestMCP.Resources.Content`, `FastestMCP.Resources.Result`,
  `FastestMCP.Resources.Text`, `FastestMCP.Resources.Binary`,
  `FastestMCP.Resources.File`, `FastestMCP.Resources.HTTP`, and
  `FastestMCP.Resources.Directory`: explicit resource helper types
- `FastestMCP.Protocol`: protocol version and capability helpers
- `FastestMCP.BackgroundTask`: local handle for submitted task work
- `FastestMCP.Transport.HTTPApp`: Plug-compatible MCP app
- `FastestMCP.Transport.StreamableHTTP`: streamable HTTP transport
- `FastestMCP.Transport.Stdio`: stdio transport entrypoint

## Current Scope

FastestMCP currently ships:

- module-owned and dynamic server definitions
- tools, resources, resource templates, and prompts
- middleware, providers, auth, and transport-independent execution
- explicit `%FastestMCP.Context{}` access to request, session, task, auth, and
  HTTP state
- `FastestMCP.Context.current!/0`, `request_context/1`, and `client_id/1` for
  narrow convenience helpers where needed
- tool, prompt, and resource-template completion handlers
- explicit tool, prompt, and resource helper structs for richer payload shaping
- unified `on_duplicate:` handling for local server definitions, runtime
  component-manager mutations, and the local provider
- per-server runtime isolation, bounded concurrency, overload control, and task
  supervision
- streamable HTTP and stdio transports
- MCP `2025-11-25` as the sole protocol version
- one JSON-RPC message per request at the configured `/mcp` endpoint
- a Plug-first HTTP embedding surface for Bandit, Phoenix, or custom Plug apps
- a connected client for streamable HTTP and stdio
- client-side sampling, elicitation, logging, and progress callbacks
- runtime component mutation through `FastestMCP.ComponentManager`
- OpenAPI-backed dynamic tool generation

The main deferred items remain:

- CLI tooling
- cluster-aware runtime behavior
- publishing automation after the first manual release path is proven
- custom app or UI layer

Standalone SSE, legacy method-specific HTTP routes, and JSON-RPC batches are
intentionally unsupported. HTTP means streamable HTTP at `/mcp` only.

## When To Use FastestMCP

FastestMCP is a good fit when:

- you want MCP server capabilities inside an Elixir or Phoenix system
- you want module-owned startup that plugs cleanly into `application.ex`
- you need supervised, crash-isolated component execution
- you want a connected Elixir client for integration tests or local tooling
- you need runtime component mutation through OTP, not an external management
  API
- you care about explicit session and task lifetimes with bounded overload
  behavior

It is not the right choice yet if you need:

- standalone SSE transport compatibility
- CLI tooling
- distributed multi-node runtime behavior out of the box
- a custom app or UI layer
