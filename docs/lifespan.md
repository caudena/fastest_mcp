# Lifespan

Lifespans let a FastestMCP server run startup and shutdown logic exactly once
per runtime.

That is the right place for state that should exist for the lifetime of the
server process tree:

- warm configuration
- shared caches
- prepared lookup tables
- long-lived clients or pooled resources
- startup bookkeeping that tools should be able to read later

Unlike per-request dependencies, lifespan hooks do not run on every call. They
run once when the server starts and clean up when the runtime stops.

## Basic Shape

Register a lifespan with `FastestMCP.add_lifespan/2`:

```elixir
server =
  FastestMCP.server("lifespan")
  |> FastestMCP.add_lifespan(fn _server ->
    {%{"started_at" => DateTime.utc_now()},
     fn ->
       IO.puts("Shutting down")
     end}
  end)
```

An enter hook can return:

- a map
- `{:ok, map}`
- `{map, cleanup_fun}`
- `{:ok, map, cleanup_fun}`
- `nil`
- `{:ok, nil}`

The returned map becomes part of `ctx.lifespan_context`.

## Accessing Lifespan State

Tools, prompts, and resources can read merged lifespan state from the context:

```elixir
server =
  FastestMCP.server("lifespan")
  |> FastestMCP.add_lifespan(fn _server ->
    %{"config" => %{"region" => "eu-west-1"}}
  end)
  |> FastestMCP.add_tool("lifespan_info", fn _arguments, ctx ->
    ctx.lifespan_context
  end)
```

That keeps startup state visible without requiring tools to know how it was
created.

## Composing Multiple Lifespans

Multiple lifespan hooks compose in declaration order:

```elixir
server =
  FastestMCP.server("lifespan")
  |> FastestMCP.add_lifespan(fn _server ->
    %{"db" => "connected", "shared" => "first"}
  end)
  |> FastestMCP.add_lifespan(fn _server ->
    %{"cache" => "warm", "shared" => "second"}
  end)
```

The merged context becomes:

```elixir
%{
  "cache" => "warm",
  "db" => "connected",
  "shared" => "second"
}
```

Later lifespans win on key conflicts. That makes override order explicit.

## Cleanup Order

Cleanup runs in reverse order.

If you register:

1. configuration
2. cache
3. client

shutdown will clean up:

1. client
2. cache
3. configuration

That ordering matters when later startup steps depend on earlier ones.

## Failure Behavior

Startup failures are cleaned up immediately.

If one lifespan has already entered and a later one raises or returns an
invalid result:

- server startup fails
- already-entered lifespan cleanups still run

That prevents partially-started runtimes from leaking resources.

## Lifespan vs Dependencies

Use lifespan when the state should exist once for the whole server runtime:

- a warmed lookup table
- a reusable client created during startup
- configuration loaded once

Use [Dependency Injection](dependency-injection.md) when the value should be
resolved once per request or background task.

In practice:

- lifespan is runtime-scoped
- dependencies are request-scoped
- session state is conversation-scoped

## Example: Shared Startup Context

```elixir
server =
  FastestMCP.server("lifespan")
  |> FastestMCP.add_lifespan(fn server ->
    {:ok, %{"server_name" => server.name, "cache" => "warm"},
     fn state ->
       IO.inspect({:stopping, state["server_name"]})
     end}
  end)
  |> FastestMCP.add_tool("show_context", fn _arguments, ctx ->
    %{
      server: ctx.server_name,
      lifespan: ctx.lifespan_context
    }
  end)
```

## Why This Shape

FastestMCP keeps lifespan small and predictable.

There is no hidden application container and no second lifecycle system.
Lifespans are just composable startup hooks that produce a merged context plus
reverse-order cleanup callbacks. That fits OTP well and keeps startup state
easy to inspect from tools.

## Related Guides

- [Dependency Injection](dependency-injection.md)
- [Context](context.md)
- [Onboarding](onboarding.md)
