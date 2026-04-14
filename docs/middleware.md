# Middleware

Middleware wraps the shared operation pipeline, not a single transport.

That is one of the key runtime decisions in FastestMCP. Middleware is applied
to:

- in-process calls
- streamable HTTP requests
- stdio requests
- mounted provider execution

So the same policy and observability rules apply regardless of how the caller
reaches the server.

## Execution Model

Middleware forms a bidirectional pipeline around the operation:

```text
request -> middleware A -> middleware B -> handler -> middleware B -> middleware A -> response
```

That means middleware can:

- inspect requests
- reject requests
- rewrite behavior before the handler runs
- observe or transform results on the way back out

## Adding Middleware

```elixir
server =
  FastestMCP.server("middleware")
  |> FastestMCP.add_middleware(FastestMCP.Middleware.logging())
  |> FastestMCP.add_middleware(
    FastestMCP.Middleware.rate_limiting(limit: 10, interval_ms: 1_000)
  )
  |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
```

Order matters. Middleware added earlier wraps middleware added later.

## Built-in Middleware

`FastestMCP.Middleware` includes constructors for:

- logging and structured logging
- timing and detailed timing
- error normalization
- retry
- rate limiting and sliding-window rate limiting
- response caching
- response limiting
- schema dereferencing
- tool injection
- ping and session keepalive support

These constructors return configured middleware objects that can be added
directly to the server definition.

## Logging and Timing

Use logging and timing middleware when you want request-level observability
across all operations:

```elixir
FastestMCP.Middleware.logging(
  include_payload_length: true,
  structured_logging: true
)

FastestMCP.Middleware.timing()
FastestMCP.Middleware.detailed_timing()
```

Read more in:

- [Logging](logging.md)
- [Telemetry](telemetry.md)

## Rate Limiting and Caching

Use middleware for cross-cutting execution policy:

```elixir
FastestMCP.Middleware.rate_limiting(limit: 20, interval_ms: 1_000)
FastestMCP.Middleware.sliding_window_rate_limiting(limit: 100, interval_ms: 60_000)
FastestMCP.Middleware.response_caching()
FastestMCP.Middleware.response_limiting(max_bytes: 100_000)
FastestMCP.Middleware.retry(max_retries: 3)
```

The response cache is local to the runtime in v0.1. See
[Runtime State and Storage](runtime-state-and-storage.md) for the current
storage model.

## Synthetic Tool Surfaces

Middleware can also inject tools into the catalog.

### Generic tool injection

```elixir
FastestMCP.Middleware.tool_injection([
  {"multiply", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => a * b} end,
   [description: "Multiply two numbers."]}
])
```

### Prompt tools

```elixir
FastestMCP.Middleware.prompt_tools()
```

This injects tool equivalents for prompt listing and rendering.

### Resource tools

```elixir
FastestMCP.Middleware.resource_tools()
```

This injects tool equivalents for listing and reading resources. It is the
FastestMCP v0.1 answer to "tool-only clients need resource access."

## Custom Middleware

Custom middleware is just a two-arity function on operations:

```elixir
middleware = fn operation, next ->
  if operation.method == "tools/call" and operation.target == "dangerous" do
    raise FastestMCP.Error, code: :permission_denied, message: "blocked by policy"
  else
    next.(operation)
  end
end

server =
  FastestMCP.server("middleware")
  |> FastestMCP.add_middleware(middleware)
```

Use custom middleware when the behavior is about request execution, not about
changing where components come from. If you are shaping component identity or
provider-backed names, use [Transforms](transforms.md) instead.

## Middleware vs Providers vs Transforms

Use:

- middleware for execution policy and observability
- providers for sourcing components
- transforms for reshaping component identity or filtering the catalog

Keeping those concerns separate is what makes larger composed servers easier to
reason about.

## Why This Shape

FastestMCP puts middleware around one shared execution path so behavior does not
fork by transport.

That keeps retries, logging, rate limiting, caching, and injected tool surfaces
aligned for direct calls, HTTP, stdio, and mounted providers.

## Related Guides

- [Logging](logging.md)
- [Providers and Mounting](providers-and-mounting.md)
- [Transforms](transforms.md)
- [Runtime State and Storage](runtime-state-and-storage.md)
