# Onboarding

This is the shortest path from a fresh Elixir app to a working MCP server.

## 1. Define a server module

Use `FastestMCP.ServerModule` when the server belongs to your application:

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
```

`base_server/1` keeps the builder DSL intact while making the module name the
server identity automatically.

## 2. Start it under your supervision tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.MCPServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

## 3. Call it in process

```elixir
FastestMCP.call_tool(MyApp.MCPServer, "sum", %{"a" => 20, "b" => 22})
# => 42

FastestMCP.call_tool(MyApp.MCPServer, "visit", %{}, session_id: "docs-session")
# => %{visits: 1, server: "Elixir.MyApp.MCPServer"}
```

Reusing the same `session_id` keeps session state attached to the same client
conversation.

## 4. Serve it over streamable HTTP

The `http:` option in `use FastestMCP.ServerModule` starts the transport for
you. If you want to embed it inside an existing Plug or Phoenix stack, use the
shared HTTP app directly:

```elixir
children = [
  {Bandit, plug: FastestMCP.http_app(MyApp.MCPServer, allowed_hosts: :localhost), port: 4100}
]
```

Phoenix forwarding works the same way:

```elixir
forward "/mcp", FastestMCP.Transport.HTTPApp,
  server_name: MyApp.MCPServer,
  path: "/mcp",
  allowed_hosts: :any
```

## 5. Connect with a client

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    session_stream: true
  )

%{items: tools} = FastestMCP.Client.list_tools(client)
FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
FastestMCP.Client.complete(
  client,
  %{"type" => "ref/prompt", "name" => "draft_release"},
  %{"name" => "environment", "value" => "pr"}
)
```

From here, branch into the focused guides:

- [Components](components.md)
- [Context](context.md)
- [Dependency Injection](dependency-injection.md)
- [Lifespan](lifespan.md)
- [Transports](transports.md)
- [Client](client.md)
- [Sampling and Interaction](sampling-and-interaction.md)
- [Background Tasks](background-tasks.md)
- [Middleware](middleware.md)
- [Providers and Mounting](providers-and-mounting.md)

## Why This Shape

FastestMCP treats the server as application infrastructure, not a separate app
framework hiding inside your codebase. Module-owned startup makes server
identity explicit, fits normal OTP supervision, and keeps the same builder API
available for dynamic or generated cases.
