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
    FastestMCP.Middleware.rate_limiting(
      max_requests_per_second: 10.0,
      burst_capacity: 20
    )
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
- tool injection
- legacy ping and session keepalive support

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
FastestMCP.Middleware.rate_limiting(max_requests_per_second: 20.0, burst_capacity: 40)
FastestMCP.Middleware.sliding_window_rate_limiting(
  max_requests: 100,
  window_minutes: 1,
  max_clients: 10_000
)
FastestMCP.Middleware.response_caching()
FastestMCP.Middleware.response_limiting(max_size: 100_000)
FastestMCP.Middleware.retry(max_retries: 3)
```

Both rate limiters default to `max_clients: 10_000` and return `:overloaded`
when live client cardinality remains full after semantic expiry. Each client
has one expiry record; the sliding-window limiter uses a queue rather than
rebuilding the entire history on every request.

Response limiting validates `max_size:` when it is constructed. A value below
the smallest valid tool-result envelope is rejected rather than producing an
invalid truncated response; mandatory `structuredContent`, `isError`, and
metadata fields are preserved when a bounded response can be represented.

The response cache is local to the runtime. See
[Runtime State and Storage](runtime-state-and-storage.md) for the current
storage model.

## Error Handling

Error handling middleware accepts one-arity loggers that receive a message or
two-arity loggers that receive `level` and `message` as separate arguments:

```elixir
FastestMCP.Middleware.error_handling(
  logger: fn level, message ->
    Logger.log(level, message)
  end
)
```

Explicit `%FastestMCP.Error{}` values can choose their log level:

```elixir
raise FastestMCP.Error,
  code: :invalid_params,
  message: "missing required input",
  log_level: :warning
```

Normalized errors are logged without traceback noise. Unexpected exceptions
still include traceback details when `include_traceback: true` is configured.

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

This injects tool equivalents for listing and reading resources when a
tool-only client needs resource access.

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
