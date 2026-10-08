# Migrating to 0.4

0.4 is an unreleased breaking Elixir API update. MCP method names, negotiated
profiles, JSON-RPC envelopes, Plug integration, and handler contexts are retained.

Consumers must upgrade their dependency requirement and lockfile together with
their API migration when 0.4 is published. Until then, validate against a local
path dependency or the freshly built package; the published 0.3 package does
not provide the new bang APIs or middleware behaviour.

## Results and errors

Effectful client and local operations return tagged results. Commands return
`:ok` or `{:error, error}`. Pure builders still raise argument-validation errors;
`start_link/1`, `child_spec/1`, predicates, and transport dispatch follow their
existing conventions.

```elixir
{:ok, result} = FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
42 = result.structured_content

result = FastestMCP.Client.call_tool!(client, "sum", %{"a" => 20, "b" => 22})
{:ok, 42} = FastestMCP.call_tool(server_name, "sum", %{"a" => 20, "b" => 22})
```

Connected tool calls always return `Client.ToolResult`. Read `.content`,
`.structured_content`, `.meta`, and `.is_error` explicitly. `.raw` preserves the
complete validated wire response, including unknown fields. The
`.structured_content_present?` flag distinguishes absent content from JSON null.
Text is never implicitly parsed as JSON. A completed MCP `isError` result remains
`{:ok, %ToolResult{is_error: true}}`; operational failures use the error tuple.

`call_tool_result/4` is a deprecated alias. Use `call_tool_task/4` for an explicit
remote task handle, and `start_tool_result/4` plus `await_tool_result/2` for a
cancellable terminal call. Handles belong to the process that created them;
connection replacement never replays an in-flight call.

## Explicit handler envelopes

Plain maps are application data, even if their keys are `content`,
`structuredContent`, `messages`, or `contents`. To select an MCP envelope:

```elixir
FastestMCP.Tools.Result.new("Finished", structured_content: %{count: 3})
FastestMCP.Prompts.Result.new([FastestMCP.Prompts.Message.new("Review this")])
FastestMCP.Resources.Result.new([FastestMCP.Resources.Content.new("Hello")])
```

The runtime retains these structs until serialization. Their `from/1` helpers
are explicit conversion boundaries for application code. `from_raw/1` accepts
validated string-keyed protocol results, as used by proxy providers.

## Middleware and providers

Remove constructor-generated `:middleware` closures and implement the behaviour:

```elixir
defmodule MyApp.LoggingMiddleware do
  @behaviour FastestMCP.Middleware
  defstruct [:logger]

  @impl true
  def call(config, operation, next) do
    config.logger.(operation.method)
    next.(operation)
  end
end
```

Add the struct directly with `FastestMCP.add_middleware/2`. Updating its fields
updates dispatch configuration. Two-argument middleware functions remain
supported. Runtime activation and cleanup stay separate from the reusable
configuration; sharing a config across servers does not share mutable state.

Providers and provider transforms expose explicit behaviours. Implement the
supported callbacks, then wrap/configure the provider before server startup.
Callback availability is checked at construction.

## Client groups

A named group registers its coordinator under the supplied name. Its supervisor
is a lifecycle handle. For an unnamed group, connect for an opaque handle:

```elixir
{:ok, group} = FastestMCP.ClientGroup.connect(clients: %{"reports" => [target: endpoint]})
{:ok, tools} = FastestMCP.ClientGroup.list_tools(group)
:ok = FastestMCP.ClientGroup.disconnect(group)
```

For an unnamed group already started under a supervisor, resolve its operation
handle once with `ClientGroup.handle/1`. Named references follow OTP replacement;
opaque handles remain pinned. Borrowed clients are never stopped with the group.
All-page tool listing, calls, and group discovery share each client's fresh
catalog; per-call authentication overrides use isolated discovery.

## Other retained boundaries

OpenAPI bodies with dynamic keys or whole-body constraints use a `body` argument
with collision-safe aliases. Request plans and validators are prepared once.
Provider-bundled extensions resolve at the root before startup, and execute
once per root. See [providers and mounting](providers-and-mounting.md) and
[extensions](extensions.md) for those composition rules.
