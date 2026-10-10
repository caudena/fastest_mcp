# FastestMCP

**MCP servers and clients for Elixir and Phoenix.**

The [Model Context Protocol](https://modelcontextprotocol.io) (MCP) lets AI
applications such as Claude, ChatGPT, Cursor, and AI-enabled editors use your
software: the model calls your *tools*, reads your *resources*, and offers your
*prompts* to the user. FastestMCP turns your Elixir or Phoenix application into
an MCP server, with ordinary functions as handlers and OTP supervision
underneath, and includes a client for calling other MCP servers.

[Getting Started](docs/getting-started.md) ·
[Core Concepts](docs/concepts.md) ·
[Phoenix](docs/phoenix.md) ·
[All guides](#documentation)

## Installation

Add `fastest_mcp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fastest_mcp, "~> 1.0"}
  ]
end
```

FastestMCP requires Elixir 1.19 or later.

## Quick start with Phoenix

Define a server module. Each tool is a function plus a description and a JSON
Schema that tell the model how to call it. The handlers call `MyApp.Notes`,
one of your application's contexts; [Getting Started](docs/getting-started.md)
builds it as a small notes store:

```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool(
      "search_notes",
      fn %{"query" => query}, _ctx -> %{notes: MyApp.Notes.search(query)} end,
      description: "Find the notes that contain a word or phrase.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    )
    |> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
      MyApp.Notes.get(id)
    end)
  end
end
```

Start it with your application, before the endpoint:

```elixir
# In lib/my_app/application.ex
children = [
  MyApp.MCPServer,
  MyAppWeb.Endpoint
]
```

Route `/mcp` to it, in a scope of its own and without the `:browser` or `:api`
pipeline; the server module is the plug of its endpoint:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer
end
```

Your app now serves MCP at `http://localhost:4000/mcp`. Connect an MCP client
to it, for example Claude Code:

```bash
claude mcp add --transport http notes http://localhost:4000/mcp
```

or call it from your own code and tests:

```elixir
FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "release"})
```

[Getting Started](docs/getting-started.md) walks through the whole setup,
including testing it, and [Phoenix](docs/phoenix.md) covers hosts,
authentication, and deployment. Without Phoenix, give the server its own
listener with `use FastestMCP.ServerModule, http: [port: 4100]`, or run it over
stdio; see [Transports](docs/transports.md).

## What you can build

| You want to | Use | Guide |
| --- | --- | --- |
| Let a model call functions in your app | Tools | [Tools](docs/tools.md) |
| Let an AI application read your data by URI | Resources and resource templates | [Resources](docs/resources.md) |
| Offer ready-made prompts to users | Prompts | [Prompts](docs/prompts.md) |
| Serve MCP from your Phoenix app | A `forward` in your router | [Phoenix](docs/phoenix.md) |
| Run a local server that a desktop app launches | The stdio transport | [Transports](docs/transports.md) |
| Require tokens or OAuth scopes | Authentication and authorization | [Authentication and Authorization](docs/auth.md) |
| Log to the client, report progress, keep state | The handler context | [Context](docs/context.md) |
| Share connections and services with handlers | Lifespans and dependencies | [Lifespans and Dependencies](docs/lifespans-and-dependencies.md) |
| Ask the user to confirm, or ask the model to write | Elicitation and sampling | [Sampling and Elicitation](docs/sampling-and-elicitation.md) |
| Run long jobs that clients can follow and cancel | Background tasks | [Background Tasks](docs/background-tasks.md) |
| Add logging, rate limits, or caching | Middleware | [Middleware](docs/middleware.md) |
| Combine servers, proxy a remote server, or turn an OpenAPI spec into tools | Providers and mounting | [Providers and Mounting](docs/providers-and-mounting.md) |
| Change the tools on offer while the server runs | Dynamic components and visibility | [Dynamic Components](docs/dynamic-components.md) |
| Show an interactive UI from a tool (MCP Apps) | Protocol extensions | [Extensions](docs/extensions.md) |
| Call other MCP servers from Elixir | The client | [Client](docs/client.md) |
| Test your server | In-process calls and clients | [Testing](docs/testing.md) |
| Trace and monitor it | Telemetry and OpenTelemetry | [Observability](docs/observability.md) |

## Protocol support

FastestMCP implements MCP `2026-07-28` and `2025-11-25` over Streamable HTTP and
stdio. Clients and servers agree on a version automatically, and one running
server serves clients of both versions at once. See
[Protocol Versions](docs/protocol-versions.md) and
[Compatibility and Scope](docs/compatibility-and-scope.md).

## Documentation

- **Start here:** [Getting Started](docs/getting-started.md) ·
  [Core Concepts](docs/concepts.md)
- **Build servers:** [Tools](docs/tools.md) · [Resources](docs/resources.md) ·
  [Prompts](docs/prompts.md) · [Context](docs/context.md) ·
  [Lifespans and Dependencies](docs/lifespans-and-dependencies.md) ·
  [Sampling and Elicitation](docs/sampling-and-elicitation.md) ·
  [Background Tasks](docs/background-tasks.md) ·
  [Authentication and Authorization](docs/auth.md)
- **Phoenix and HTTP:** [Phoenix](docs/phoenix.md) ·
  [Transports](docs/transports.md) · [Testing](docs/testing.md)
- **Operations:** [Observability](docs/observability.md) ·
  [Production](docs/production.md) · [Troubleshooting](docs/troubleshooting.md)
- **Client:** [Client](docs/client.md) ·
  [Client Callbacks](docs/client-callbacks.md) ·
  [Client Authentication](docs/client-auth.md)
- **Advanced:** [Middleware](docs/middleware.md) ·
  [Providers and Mounting](docs/providers-and-mounting.md) ·
  [Transforms](docs/transforms.md) ·
  [Versioning and Visibility](docs/versioning-and-visibility.md) ·
  [Dynamic Components](docs/dynamic-components.md) ·
  [Extensions](docs/extensions.md)
- **Reference:** [Protocol Versions](docs/protocol-versions.md) ·
  [Pagination](docs/pagination.md) ·
  [Schema Validation](docs/schema-validation.md) ·
  [Compatibility and Scope](docs/compatibility-and-scope.md) ·
  [Migrating to 1.0](docs/migrating-to-1.0.md) · [Changelog](CHANGELOG.md)

## Contributing

See [CONTRIBUTING.md](https://github.com/caudena/fastest_mcp/blob/master/CONTRIBUTING.md)
for the checks to run and how the docs are written.

## License

Apache-2.0; see [LICENSE](https://github.com/caudena/fastest_mcp/blob/master/LICENSE).
