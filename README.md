# FastestMCP

**OTP-native MCP servers and clients for Elixir.**

FastestMCP provides supervised server runtimes, connected clients, strict
protocol handling, authorization, tasks, middleware, and providers for ordinary
Elixir and Phoenix applications. It is designed around explicit lifecycles,
bounded work, and familiar OTP supervision rather than a separate runtime.

[Protocol support](#protocol-support) · [Installation](#installation) ·
[Quick start](#quick-start) · [Examples](#server-and-component-dsl) ·
[Phoenix and authentication](#phoenix-and-authentication) ·
[Documentation](#documentation)

## Protocol support

FastestMCP supports both MCP revisions from the same server, process, and
endpoint:

| Revision | Profile | Startup and state | Tasks |
| --- | --- | --- | --- |
| MCP `2026-07-28` | Modern and preferred | `server/discover`; request-scoped protocol metadata; sessionless HTTP | Optional `io.modelcontextprotocol/tasks` v2 extension |
| MCP `2025-11-25` | Legacy compatibility | `initialize`, then `notifications/initialized`; server-issued HTTP session | Optional legacy Tasks v1 |

Both profiles are available over Streamable HTTP and stdio. Connected clients
prefer `2026-07-28` by default, with transport-specific compatibility fallback.
Exact version pins are available for migrations and compatibility testing.

```elixir
FastestMCP.supported_protocol_versions()
# => ["2026-07-28", "2025-11-25"]

FastestMCP.current_protocol_version()
# => "2026-07-28"
```

A single running server may serve modern and legacy clients concurrently;
protocol state belongs to each request or legacy session, not to a global
server switch. See [Protocol Versions](docs/protocol-versions.md) for the wire
and lifecycle differences.

## Highlights

| Area | What FastestMCP provides |
| --- | --- |
| Server runtime | Module-owned or dynamic servers with supervised execution, bounded concurrency, overload control, and isolated lifecycles |
| Connected client | Streamable HTTP, stdio, and in-process transports with callbacks, progress, subscriptions, Tasks, and automatic protocol negotiation |
| Components | Tools, resources, resource templates, prompts, completion, runtime mutation, transforms, and visibility policies |
| Security | Pluggable authentication, RFC 9728 protected-resource metadata, scope-aware authorization, and secure-by-default lexical resource-template screening |
| Extensibility | Middleware, providers, mounted servers, active negotiated extensions, request-scoped proxying, and bounded tool search |
| Protocol features | MRTR, modern and legacy Tasks, MCP Apps metadata/resources, pagination, logging, cancellation, and JSON Schema validation |
| State and operations | Request state, legacy transport sessions, application sessions, background tasks, telemetry, and structured cleanup |

## Installation

Add FastestMCP to your dependencies:

```elixir
def deps do
  [
    {:fastest_mcp, "~> 0.3.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

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

Connect over HTTP with automatic latest-first negotiation:

```elixir
client =
  FastestMCP.Client.connect!("http://localhost:4100/mcp",
    protocol_version: :auto,
    client_info: %{"name" => "my_app", "version" => "1.0.0"}
  )

FastestMCP.Client.protocol_version(client)
# => "2026-07-28"

result = FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
result["structuredContent"]
# => 42

:ok = FastestMCP.Client.disconnect(client)
```

The full onboarding path, including transport startup and the first connected
client call, lives in [docs/onboarding.md](docs/onboarding.md).

## Server and component DSL

The builder API composes every component onto one server definition. Tools,
resources, templates, and prompts then share the same middleware,
authorization, visibility, task, and telemetry pipeline.

```elixir
input_schema = %{
  "type" => "object",
  "properties" => %{
    "environment" => %{
      "type" => "string",
      "enum" => ["staging", "production"]
    }
  },
  "required" => ["environment"]
}

server =
  FastestMCP.server("operations")
  |> FastestMCP.add_tool(
    "deployment_status",
    fn %{"environment" => environment}, _ctx ->
      FastestMCP.Tools.Result.new(
        "#{environment} is healthy",
        structured_content: %{environment: environment, status: "healthy"}
      )
    end,
    description: "Read the current deployment status",
    input_schema: input_schema
  )
  |> FastestMCP.add_resource("config://environments", fn _arguments, _ctx ->
    %{environments: ["staging", "production"]}
  end)
  |> FastestMCP.add_resource_template(
    "deployments://{environment}/latest",
    fn %{"environment" => environment}, _ctx ->
      %{environment: environment, revision: "2026.08.14", status: "healthy"}
    end
  )
  |> FastestMCP.add_prompt(
    "review_deployment",
    fn %{"environment" => environment}, _ctx ->
      "Review the latest #{environment} deployment and identify operational risks."
    end,
    arguments: [%{name: "environment", required: true}]
  )

{:ok, _pid} = FastestMCP.start_server(server)
```

Use `FastestMCP.ServerModule` when the definition belongs in an application
supervision tree, as shown in the quick start. Use `FastestMCP.server/2` for
dynamic definitions, tests, and provider composition.

## MCP Apps

MCP Apps link an ordinary tool to a `ui://` HTML resource. The tool must keep a
useful text fallback, while a negotiated Apps-capable client receives the UI
metadata and document.

```elixir
alias FastestMCP.Apps

app_uri = "ui://reports/summary.html"
app_options = [
  csp: %{"connectDomains" => ["https://api.example.com"]},
  prefers_border: true
]

server =
  FastestMCP.server("reports",
    extensions: %{Apps.extension_id() => %{}}
  )
  |> FastestMCP.add_tool(
    "show_report",
    fn _arguments, _ctx ->
      FastestMCP.Tools.Result.new(
        "The report is ready.",
        structured_content: %{status: "ready"}
      )
    end,
    meta: Apps.tool_meta(app_uri)
  )
  |> FastestMCP.add_resource(
    app_uri,
    fn _arguments, _ctx ->
      Apps.result(
        app_uri,
        "<!doctype html><html><body><main>Report</main></body></html>",
        app_options
      )
    end,
    mime_type: Apps.mime_type(),
    meta: Apps.resource_meta(app_options)
  )
```

The connected client opts in with the supported Apps MIME type:

```elixir
client =
  FastestMCP.Client.connect!(endpoint,
    extensions: %{Apps.extension_id() => Apps.client_settings()}
  )
```

FastestMCP owns the MCP metadata and resource boundary. The consuming Host owns
HTML rendering, iframe sandboxing, CSP enforcement, permissions, consent, and
the Host/View bridge.

## Phoenix and authentication

When Phoenix owns the listener, supervise the MCP server without its standalone
HTTP transport. Normalize the identity already verified by your application and
apply component scopes on the same server definition:

```elixir
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule,
    otp_app: :my_app,
    protected_resource: [
      resource: "https://mcp.example.com/mcp",
      authorization_servers: ["https://auth.example.com"],
      scopes_supported: ["reports:read", "reports:write"],
      required_scopes: ["reports:read"]
    ]

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_auth(
      FastestMCP.Auth.from_assign(:mcp_identity,
        principal: fn identity -> {identity.issuer, identity.subject} end,
        audiences: fn identity -> identity.verified_audiences end,
        scopes: fn identity -> identity.verified_scopes end,
        auth: fn identity -> %{source: :phoenix, subject: identity.subject} end
      )
    )
    |> FastestMCP.add_tool(
      "create_report",
      fn arguments, ctx -> MyApp.Reports.create!(arguments, actor: ctx.principal) end,
      auth: FastestMCP.Authorization.require_scopes(["reports:write"])
    )
  end
end
```

Add `MyApp.MCPServer` before `MyAppWeb.Endpoint` in the application supervision
tree:

```elixir
children = [
  MyApp.Repo,
  MyApp.MCPServer,
  MyAppWeb.Endpoint
]
```

Mount RFC 9728 discovery publicly, then mount the MCP endpoint behind a
non-halting identity verifier:

```elixir
pipeline :mcp_auth do
  # Verifies signature/introspection, issuer, expiry, audience, and scopes.
  # It assigns :mcp_identity when valid, but never redirects or halts.
  plug MyAppWeb.MCPBearerVerifier
end

scope "/" do
  forward "/.well-known/oauth-protected-resource/mcp",
          FastestMCP.Transport.WellKnownHTTP,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    base_url: "https://mcp.example.com",
    allowed_hosts: ["mcp.example.com"]
end

scope "/" do
  pipe_through :mcp_auth

  forward "/mcp", FastestMCP.Transport.HTTPApp,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    base_url: "https://mcp.example.com",
    allowed_hosts: ["mcp.example.com"],
    auth_assigns: [:mcp_identity]
end
```

The verifier must not issue its own redirect or challenge: FastestMCP owns the
MCP `401`/`403` and `WWW-Authenticate` response. Keep the well-known route
outside authentication, use a narrow `auth_assigns:` allowlist, and return only
audiences and scopes that the host actually verified. FastestMCP is the
protected resource server; token issuance, JWT verification, introspection,
and login UI remain application or authorization-server responsibilities.

## Upgrading

FastestMCP `0.3.x` keeps the complete MCP `2025-11-25` profile while adding
`2026-07-28` as the preferred modern profile. Existing `0.2.x` deployments may
pin `protocol_version: "2025-11-25"` during a staged migration, then move to
`:auto` when modern peers are ready.

Applications coming from `0.1.x` must also adopt the JSON-RPC-only Streamable
HTTP boundary introduced in `0.2.0`. Review the
[changelog](CHANGELOG.md#020---2026-08-12) and
[transport migration guide](docs/transports.md#migrating-from-01) before
deploying.

## Documentation

| Path | Guides |
| --- | --- |
| Start here | [Onboarding](docs/onboarding.md) · [Why FastestMCP](docs/why-fastest-mcp.md) · [Protocol Versions](docs/protocol-versions.md) · [Compatibility and Scope](docs/compatibility-and-scope.md) |
| Build | [Components](docs/components.md) · [Tools](docs/tools.md) · [Resources](docs/resources.md) · [Prompts](docs/prompts.md) · [Context](docs/context.md) · [Dependency Injection](docs/dependency-injection.md) · [Lifespan](docs/lifespan.md) |
| Connect and extend | [Client](docs/client.md) · [Transports](docs/transports.md) · [Providers and Mounting](docs/providers-and-mounting.md) · [Protocol Extensions](docs/extensions.md) · [Sampling and Interaction](docs/sampling-and-interaction.md) · [Pagination](docs/pagination.md) · [Progress](docs/progress.md) |
| Secure and operate | [Auth](docs/auth.md) · [Phoenix Deployment](docs/phoenix-deployment.md) · [Middleware](docs/middleware.md) · [Background Tasks](docs/background-tasks.md) · [Runtime State and Storage](docs/runtime-state-and-storage.md) · [Logging](docs/logging.md) · [Telemetry](docs/telemetry.md) · [Testing](docs/testing.md) |
| Advanced | [Dynamic Component Manager](docs/component-manager.md) · [Transforms](docs/transforms.md) · [Versioning and Visibility](docs/versioning-and-visibility.md) · [Schema Validation](docs/schema-validation.md) |

## Known boundaries

FastestMCP intentionally does not provide:

- standalone SSE transport compatibility
- legacy method-specific MCP routes or JSON-RPC batches
- CLI tooling
- distributed multi-node runtime behavior out of the box
- a browser/native Apps Host and View runtime

HTTP support means Streamable HTTP at the configured MCP endpoint, `/mcp` by
default. FastestMCP preserves MCP Apps metadata and resources, but rendering,
sandboxing, and the Host/View bridge belong to the consuming host.
