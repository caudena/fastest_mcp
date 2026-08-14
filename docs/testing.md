# Testing

FastestMCP is designed to be tested from normal Elixir code.

You do not need a separate inspector or a separate application container to get
confidence in your server. In practice there are three useful layers:

1. direct in-process tests for handler behavior
2. transport tests for HTTP or stdio behavior
3. client tests for session, callback, and protocol flows

## 1. In-process Tests

Most server behavior can be tested with the direct API:

```elixir
test "sum tool works" do
  server_name = "sum-" <> Integer.to_string(System.unique_integer([:positive]))

  server =
    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)

  assert {:ok, _pid} = FastestMCP.start_server(server)
  on_exit(fn -> FastestMCP.stop_server(server_name) end)

  assert 42 == FastestMCP.call_tool(server_name, "sum", %{"a" => 20, "b" => 22})
end
```

Use this layer for:

- handler return values
- context behavior
- session state
- dependency cleanup
- lifespan state
- background task semantics

It is the fastest test loop and usually the right default.

## 2. Transport Tests

When you need to verify transport behavior, start the HTTP transport under test
and connect a client to it:

```elixir
assert {:ok, _pid} = start_supervised(MyApp.MCPServer)

bandit =
  start_supervised!(
    {Bandit,
     plug:
       {FastestMCP.Transport.HTTPApp,
        server_name: MyApp.MCPServer, path: "/mcp", allowed_hosts: :localhost},
     scheme: :http,
     port: 0}
  )

{:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

client =
  FastestMCP.Client.connect!("http://127.0.0.1:#{port}/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"}
  )

assert 42 == FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
```

Use this layer when you care about:

- session negotiation
- auth headers or access tokens
- client callbacks
- progress or log notifications
- streamable HTTP behavior

For a raw `2025-11-25` transport test, exercise the full lifecycle: initialize
without a session header, retain the server-issued id, send
`notifications/initialized`, then include both the session id and
`MCP-Protocol-Version: 2025-11-25` on later requests. A raw `2026-07-28` test
instead sends `server/discover` and then carries modern protocol, client, and
capability metadata on each stateless request. Each POST contains one JSON-RPC
message rather than a batch in either profile.

The repository's `test/support/raw_peer.ex` is a minimal legacy spec-shaped
peer used by `raw_peer_acceptance_matrix_test.exs` to run roots, sampling,
form/URL elicitation, requester-task, and ping workflows over unprotected HTTP
JSON + GET SSE, unprotected POST SSE, protected-resource HTTP JSON + GET SSE,
and stdio. Separate modern raw-peer tests cover request-scoped MRTR,
subscriptions, progress, cancellation, and task status without legacy ping or
session replay. The emulator is intentionally lower-level than
`FastestMCP.Client`, so a client helper cannot accidentally hide a server wire
defect.

## 3. Background Task and Interaction Tests

Background task behavior is testable through the same public API:

```elixir
task = FastestMCP.call_tool(MyApp.MCPServer, "slow", %{}, task: true)
assert %FastestMCP.BackgroundTask{} = task
assert :done == FastestMCP.await_task(task, 1_000)
```

Interactive tasks can be driven by sending task input:

```elixir
task = FastestMCP.call_tool(MyApp.MCPServer, "approve_release", %{}, task: true)

FastestMCP.send_task_input(
  MyApp.MCPServer,
  task.task_id,
  :accept,
  %{"confirmed" => true}
)

assert %{approved: true} = FastestMCP.await_task(task, 1_000)
```

## What To Test At Each Layer

Use direct tests for:

- component behavior
- dependency injection
- context state
- visibility and versioning
- task state transitions

Use transport or client tests for:

- session headers
- authentication
- client callbacks
- streamable HTTP flows
- protocol-level features that only make sense over a live connection

## Docs and Example Verification

This repo also keeps a docs fixture and a docs example test lane so guide
snippets keep matching real runtime behavior. That is worth copying into your
own application when your server becomes a shared internal platform.

The release gate uses
`@modelcontextprotocol/conformance@0.2.0-alpha.11` in
`test/conformance/package-lock.json`, installs it with `npm ci`, and invokes it
with `npx --no-install`. It runs the runner's frozen requirement sets rather
than a moving active suite:

1. the 30 server and 18 client scenarios required by `2025-11-25`
2. the 37 server and 32 client scenarios required by `2026-07-28`
3. nine selected Tasks scenarios and three selected authorization-extension
   scenarios, each forced because extensions have independent version timelines

The gate parses the official requirement listing, requires every expected
scenario to produce a `checks.json`, and rejects empty evidence and every
unexpected status. There is no general expected-failure baseline or protocol
translator. Four alpha.11 defects are isolated by exact evidence checks:

- its frozen 2025 SSE-retry fixture replies with `2025-03-26`; a loopback-only
  scenario proxy rewrites that one initialize response to the requirements
  revision without changing production negotiation
- its Tasks wire validator applies core `CallToolResult` to the extension's
  valid flat `CreateTaskResult`; only that exact diagnostic is tolerated, while
  every Tasks semantic check must pass
- its modern standard-header fixture asks for removed `initialize` and
  `notifications/initialized` requests; only those two exact skips are accepted
- its stateless fixture expects `-32602` when a present 2026 protocol header has
  no matching body protocol field, while the final HTTP transport rule requires
  `HeaderMismatch` (`-32020`); only those two exact diagnostics are accepted

The runner currently has no Apps scenario. Its Tasks status-notification
scenario is also unexecutable while the upstream fixture moves to
`subscriptions/listen`; FastestMCP does not report either as an official pass.
Native Apps metadata/round-trip tests and native task subscription/demultiplexing
tests own those release gates instead.

Official runner evidence is one layer, not the whole support claim. Native
feature tests, raw-peer transport tests, schema validation, docs
with warnings as errors, and a fresh-package consumer exercised over both
protocol revisions and transports remain independent release requirements.

## Why This Shape

FastestMCP keeps the server runtime accessible from Elixir tests on purpose.

You can test the logic in process, then add transport or client coverage only
where it matters. That produces a much tighter loop than forcing every test to
go through an external inspector or network boundary.

## Related Guides

- [Onboarding](onboarding.md)
- [Client](client.md)
- [Background Tasks](background-tasks.md)
- [Telemetry](telemetry.md)
