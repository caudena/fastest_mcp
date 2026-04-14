# Sampling and Interaction

FastestMCP exposes low-level client bridges on `FastestMCP.Context`, then wraps
the common cases with `FastestMCP.Sampling` and `FastestMCP.Interact`.

That split matters:

- `Context` is the protocol bridge
- `Sampling` and `Interact` are the ergonomic Elixir surfaces

Use the low-level helpers when you need exact control. Use the higher-level
helpers when you want handler code that reads like normal Elixir.

## Sampling

Sampling lets a server ask the connected client to create a model response.

The low-level API is `Context.sample/3`. The higher-level API is
`FastestMCP.Sampling`.

### Prompt-oriented Sampling

```elixir
server =
  FastestMCP.server("sampling")
  |> FastestMCP.add_tool("summarize", fn _arguments, ctx ->
    response = FastestMCP.Sampling.run!(ctx, "Summarize this text", max_tokens: 64)
    %{text: response.text}
  end)
```

### Message-oriented Sampling

```elixir
response =
  FastestMCP.Sampling.run!(
    ctx,
    [
      %{
        role: "user",
        content: %{type: "text", text: "Summarize this text"}
      }
    ],
    max_tokens: 64
  )
```

### Prepared Tools

If you want the model-facing sampling request to include local tools, prepare
them first:

```elixir
tools = FastestMCP.Sampling.prepare_tools(MyApp.MCPServer)

response =
  FastestMCP.Sampling.run!(
    ctx,
    prompt: "Use tools if needed",
    tools: tools,
    max_tokens: 128
  )
```

`prepare_tools/2` accepts:

- a running server name
- a list of FastestMCP tools
- sampling tool definitions
- plain function captures with metadata

### Normalized Response

`FastestMCP.Sampling.run!/3` returns a normalized response struct with:

- `text`
- `content`
- `raw`

That keeps the common case simple without hiding the full protocol payload.

## Interaction and Elicitation

Elicitation asks the client for structured human input.

The low-level API is `Context.elicit/4`, which returns explicit elicitation
result structs. The higher-level API is `FastestMCP.Interact`, which turns the
common cases into normal Elixir return values.

### Confirm

```elixir
case FastestMCP.Interact.confirm(ctx, "Ship this release?") do
  {:ok, true} -> %{approved: true}
  {:ok, false} -> %{approved: false}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
end
```

### Text

```elixir
case FastestMCP.Interact.text(ctx, "What should we call this release?") do
  {:ok, value} -> %{name: value}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
end
```

### Choose

```elixir
FastestMCP.Interact.choose(
  ctx,
  "Choose an environment",
  [dev: "development", prod: "production"]
)
```

### Form

```elixir
FastestMCP.Interact.form(
  ctx,
  "Collect release details",
  [
    {:title, [type: :string, required: true]},
    {:urgent, [type: :boolean, required: true]},
    {:owner, [type: :string, required: false]}
  ]
)
```

## Background Tasks and Interaction

Interactive workflows usually belong on background tasks.

That is what allows:

- the original request to return a task handle
- the task to move into `input_required`
- the caller to respond later through `FastestMCP.send_task_input/5`

```elixir
task = FastestMCP.call_tool(MyApp.MCPServer, "approve_release", %{}, task: true)

FastestMCP.send_task_input(
  MyApp.MCPServer,
  task.task_id,
  :accept,
  %{"confirmed" => true}
)
```

## Client Requirements

Sampling and interaction are protocol features. They require a connected client
that knows how to answer them.

For client-driven tests or local tools, pass handlers when connecting:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    sampling_handler: fn _messages, _params -> %{"text" => "sampled"} end,
    elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
  )
```

## Choosing The Right Level

Use:

- `Context.sample/3` or `Context.elicit/4` when you want direct protocol access
- `FastestMCP.Sampling` when you want normalized sampling responses
- `FastestMCP.Interact` when you want common interaction patterns as normal
  Elixir values

## Why This Shape

Sampling and elicitation still belong to the MCP protocol, but handler code
should not feel like raw JSON-RPC plumbing.

FastestMCP keeps the protocol bridge on the context and adds a thin Elixir
surface on top. That preserves the runtime behavior while keeping handler code
readable.

## Related Guides

- [Background Tasks](background-tasks.md)
- [Client](client.md)
- [Context](context.md)
- [Testing](testing.md)
