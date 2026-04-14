# Progress

FastestMCP supports explicit progress reporting from handlers and background
tasks.

This matters when work is slow enough that the caller should see incremental
status instead of waiting for one final result:

- long-running tools
- background tasks
- multi-step resource generation
- workflows that need human-visible milestones

## Two Ways To Report Progress

The low-level API is `FastestMCP.Context.report_progress/4`:

```elixir
FastestMCP.Context.report_progress(ctx, 1, 3, "Fetched source data")
```

The higher-level API is the request-local progress helper:

```elixir
progress = FastestMCP.Context.progress(ctx)
progress = FastestMCP.Progress.set_total(progress, 3)
progress = FastestMCP.Progress.increment(progress)
progress = FastestMCP.Progress.set_message(progress, "Fetched source data")
```

Use the helper when you want the runtime to track current state in one place.
Use `report_progress/4` when you already know the values and just want to emit
them directly.

## Basic Example

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("progress")
  |> FastestMCP.add_tool(
    "track",
    fn _arguments, ctx ->
      progress = Context.progress(ctx)

      progress = FastestMCP.Progress.set_total(progress, 3)
      progress = FastestMCP.Progress.increment(progress)
      progress = FastestMCP.Progress.set_message(progress, "Step 1")

      %{
        current: FastestMCP.Progress.current(progress),
        total: FastestMCP.Progress.total(progress),
        message: FastestMCP.Progress.message(progress)
      }
    end,
    task: true
  )
```

## Immediate Calls vs Background Tasks

Progress behaves differently depending on the execution mode:

- immediate calls can still use the progress helper for local state
- background tasks persist progress onto the task record
- connected clients can receive progress notifications while the task runs

That means the same handler code can work for both in-process tests and remote
interactive clients.

## Client-side Consumption

Connected clients can register a `progress_handler`:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    progress_handler: &IO.inspect/1
  )
```

This is the cleanest way to watch long-running work from integration tests or
local tooling.

## Progress and Background Task State

When progress is reported from a background task, FastestMCP stores it on the
task itself. That means you can:

- inspect the latest progress through `FastestMCP.fetch_task/1`
- await the final result with `FastestMCP.await_task/2`
- forward progress updates to subscribed clients

The stored progress includes:

- current
- total
- message
- `reported_at`

## Choosing Between Progress and Logging

Use progress when the caller needs structured task state.

Use [Logging](logging.md) when the caller needs human-readable events that do
not necessarily map to a numeric completion model.

In practice:

- progress answers "how far along is this work?"
- logs answer "what just happened?"

## Why This Shape

FastestMCP treats progress as runtime state, not just output text.

The helper updates request-local state, task state, and client notifications in
one place. That keeps background tasks, connected clients, and local handlers
aligned instead of inventing one progress model per transport.

## Related Guides

- [Background Tasks](background-tasks.md)
- [Logging](logging.md)
- [Testing](testing.md)
