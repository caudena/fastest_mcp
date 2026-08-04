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

For raw transport tests, exercise the full lifecycle: initialize without a
session header, retain the server-issued id, send `notifications/initialized`,
then include both the session id and `MCP-Protocol-Version: 2025-11-25` on later
requests. Each POST must contain one JSON-RPC message rather than a batch.

The repository's `test/support/raw_peer.ex` is a minimal spec-shaped peer used
by `raw_peer_acceptance_matrix_test.exs` to run one shared roots, sampling,
form/URL elicitation, requester-task, and ping workflow over unprotected HTTP
JSON + GET SSE, unprotected POST SSE, protected-resource HTTP JSON + GET SSE,
and stdio. Richer raw-peer tests add progress, cancellation, task status, and
failure cases. The emulator is intentionally lower-level than
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

The 0.2 release gate pins
`@modelcontextprotocol/conformance@0.1.16` in
`test/conformance/package-lock.json`, installs it with `npm ci`, and invokes it
with `npx --no-install` plus explicit `--spec-version 2025-11-25`. Conformance
is split into independently visible lanes:

1. native ExUnit and real subprocess/TCP tests
2. all 32 official server scenarios through a narrowly scoped test-only runner
   compatibility adapter
3. all 18 official client scenarios through a test-only adapter that calls public
   `FastestMCP.Client` APIs

Runner `0.1.16` advertises its new SSE scenarios for `2025-11-25` but sends
`MCP-Protocol-Version: 2025-03-26` on their manually constructed follow-up
requests. Its client `sse-retry` scenario also returns `2025-03-26` from
`initialize` despite being selected as `2025-11-25`. Production continues to
reject that stale protocol version. The test-only adapters change only those
exact runner values, and unit tests prove current, absent, unrelated, and later
response values remain untouched. Both official lanes require the exact
scenario count, one evidence file per scenario, no skipped scenario, no failure
or warning status, and a zero exit status. No expected-failure baseline or
manual failure allowance is part of the release gate.

A green shimmed runner is not evidence of full support. Native feature tests,
raw-peer transport tests, schema checksum verification, docs with warnings as
errors, and fresh-package consumer smoke tests remain
independent release requirements.

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
