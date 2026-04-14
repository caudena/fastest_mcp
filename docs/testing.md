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
     plug: {FastestMCP.Transport.HTTPApp, server_name: MyApp.MCPServer, path: "/mcp", allowed_hosts: :any},
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
