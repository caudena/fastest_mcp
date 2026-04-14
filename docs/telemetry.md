# Telemetry

FastestMCP emits telemetry events for core runtime activity and also creates
OpenTelemetry spans for server-side tracing.

That gives you two levels of observability:

- `:telemetry` events for direct Elixir instrumentation
- OpenTelemetry spans and trace propagation for distributed tracing systems

## Telemetry Events

FastestMCP emits events around operation and auth work.

Common events include:

- `[:fastest_mcp, :operation, :start]`
- `[:fastest_mcp, :operation, :stop]`
- `[:fastest_mcp, :operation, :exception]`
- `[:fastest_mcp, :auth, :start]`
- `[:fastest_mcp, :auth, :stop]`
- `[:fastest_mcp, :auth, :exception]`

Attach handlers using standard `:telemetry` APIs:

```elixir
handler_id = "fastest-mcp-docs"

:telemetry.attach_many(
  handler_id,
  [
    [:fastest_mcp, :operation, :start],
    [:fastest_mcp, :operation, :stop],
    [:fastest_mcp, :operation, :exception]
  ],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

The metadata includes fields such as the MCP method and server name, which is
usually enough to build metrics and dashboards.

## OpenTelemetry Spans

FastestMCP also creates server spans around operations and provider delegation.

That is useful when you want traces that connect:

- inbound HTTP or stdio requests
- auth work
- provider delegation
- tool, resource, or prompt execution

FastestMCP uses W3C trace context propagation through request metadata and
headers, so trace context can move through the runtime without custom glue in
every handler.

## What FastestMCP Traces For You

FastestMCP already handles:

- span naming from MCP method and target
- attributes for server name, method, component key, transport, session, and
  request id
- exception recording on failed spans
- trace context extraction and injection

Most applications do not need to call the internal tracing helper module
directly. The runtime instrumentation is the default.

## Telemetry vs Logging

Use [Logging](logging.md) for human-readable events.

Use telemetry when you need:

- counters
- durations
- traces
- monitoring integrations
- alerts and dashboards

Logging and telemetry complement each other, but they are not interchangeable.

## Example Test

Telemetry is straightforward to verify in ExUnit:

```elixir
:telemetry.attach_many(
  "fastest-mcp-test",
  [
    [:fastest_mcp, :operation, :start],
    [:fastest_mcp, :operation, :stop],
    [:fastest_mcp, :operation, :exception]
  ],
  fn event, measurements, metadata, pid ->
    send(pid, {:telemetry, event, measurements, metadata})
  end,
  self()
)

assert %{status: "ok"} == FastestMCP.call_tool(server_name, "ok", %{})
assert_receive {:telemetry, [:fastest_mcp, :operation, :start], _, _}
assert_receive {:telemetry, [:fastest_mcp, :operation, :stop], %{duration: duration}, _}
assert duration > 0
```

## Why This Shape

FastestMCP does not make you choose between BEAM-native telemetry and modern
trace pipelines.

The runtime emits standard `:telemetry` events for local Elixir integrations
and layers OpenTelemetry spans on top for tracing systems. That keeps the
runtime observable without forcing one instrumentation style on every user.

## Related Guides

- [Logging](logging.md)
- [Testing](testing.md)
- [Middleware](middleware.md)
