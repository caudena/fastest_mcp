# Middleware

Middleware is code that runs around every request your server handles, from
an in-process call, HTTP, or stdio alike. Use it for rules that apply across
your tools, resources, and prompts, such as rate limits, caching, audit logs,
or blocking calls during maintenance, instead of repeating them in each
handler.

```elixir
FastestMCP.server("middleware-rate-limit")
|> FastestMCP.add_middleware(
  FastestMCP.Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 2)
)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("middleware-rate-limit", "search_notes")
# => %{notes: []}

FastestMCP.call_tool!("middleware-rate-limit", "search_notes")
# => %{notes: []}

{:error, error} = FastestMCP.call_tool("middleware-rate-limit", "search_notes")
{error.code, error.message}
# => {:rate_limited, "rate limit exceeded for client: global"}
```

## How requests flow

Every request, whatever the transport, takes the same path through the
server:

```text
request ─> authentication ─> middleware A ─> middleware B ─> component ─> handler
                                                                             │
response <── output check <── middleware A <── middleware B <── result <─────┘
```

1. FastestMCP authenticates the request (see
   [Authentication and Authorization](auth.md)). A request that fails
   authentication never reaches middleware.
2. Middleware runs in the order you added it. Each one receives the request as
   a `FastestMCP.Operation` and a `next` function that runs the rest of the
   chain.
3. At the end of the chain, FastestMCP finds the component, applying
   visibility rules, authorization, and versions, validates the arguments, and
   runs the handler.
4. The result travels back out through the middleware in reverse order, and
   FastestMCP checks a tool's result against its output schema.

So a middleware can inspect a request, reject it, answer it itself, or change
the result on the way back. It sees every kind of request: calls, reads, and
prompt renders, but also lists, completions, `initialize`, and `ping`. A
failure in a later step, such as an unknown tool or invalid arguments, comes
back through the middleware as an error.

A [mounted server](providers-and-mounting.md#mounting-servers) keeps its own
middleware: it runs around the calls of that server's components, inside the
parent's chain, but not around the parent's lists.

## Adding middleware

`FastestMCP.add_middleware/2` appends middleware to a server definition.
Middleware added first wraps everything added after it, so add the middleware
that should see every outcome, such as logging and error handling, first:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_middleware(FastestMCP.Middleware.error_handling())
  |> FastestMCP.add_middleware(FastestMCP.Middleware.rate_limiting(max_requests_per_second: 20.0))

  # Then add your tools, resources, and prompts.
end
```

`FastestMCP.server/2` also takes a list in its `middleware:` option. A
middleware value is configuration: you can add the same value to several
servers, and each server keeps its own state, such as its own rate limiter.

## Built-in middleware

`FastestMCP.Middleware` builds these; its function docs list every option:

| Function | What it does |
| --- | --- |
| `rate_limiting/1` | Limits each client to a steady rate, with bursts |
| `sliding_window_rate_limiting/1` | Limits each client to a number of requests per window of minutes |
| `response_caching/1` | Caches lists, resource reads, prompts, and tool results |
| `response_limiting/1` | Truncates tool results larger than a size |
| `retry/1` | Retries failed requests, with exponential backoff |
| `error_handling/1` | Logs and counts failures |
| `logging/1`, `structured_logging/1` | Logs each request and its outcome |
| `timing/1`, `detailed_timing/1` | Logs how long each request took |
| `tool_injection/2`, `prompt_tools/1`, `resource_tools/1` | Adds tools ahead of the server's own |
| `ping/1` | Pings the clients of `2025-11-25` sessions at an interval |

For logging and timing, see
[Logging requests](observability.md#logging-requests) in the Observability
guide.

### Rate limiting

`rate_limiting/1` gives each client a token bucket: `max_requests_per_second`
(default 10) is the steady rate and `burst_capacity` (default twice the rate)
the burst. `sliding_window_rate_limiting/1` allows `max_requests` per client
in each window of `window_minutes`. Without `get_client_id:`, all requests
share one limit; pass a function of the operation to limit each user
separately:

```elixir
FastestMCP.Middleware.rate_limiting(
  max_requests_per_second: 5.0,
  burst_capacity: 10,
  get_client_id: fn operation -> operation.context.principal["sub"] end
)
```

A request over the limit fails with `:rate_limited`, and its details include
`retry_after_seconds`. Requests whose function returns `nil` share one limit.

### Response caching

`response_caching/1` keeps successful results and answers the same request
from the cache. Lists are kept for 5 minutes, and resource reads, prompts, and
tool results for an hour. Entries are kept separately for each authenticated
caller, so one user never receives another's cached result.

> #### Tool calls are cached too {: .warning}
>
> By default, a second call of a tool with the same arguments returns the
> cached result without running the handler, so a tool that changes data,
> such as `add_note`, does nothing the second time. Cache only the tools whose
> results are safe to reuse, with `included_tools:`, or turn tool caching off
> with `call_tool: [enabled: false]`.

This cache keeps tool lists for a minute, and caches the results of
`search_notes` only:

```elixir
cache =
  FastestMCP.Middleware.response_caching(
    list_tools: [ttl_ms: 60_000],
    call_tool: [included_tools: ["search_notes"]]
  )

FastestMCP.server("middleware-cache")
|> FastestMCP.add_middleware(cache)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("middleware-cache", "search_notes")
FastestMCP.call_tool!("middleware-cache", "search_notes")

FastestMCP.Middleware.cache_statistics(cache)["tools/call"]
# => %{evictions: 0, expired: 0, hits: 1, misses: 1, puts: 1, skipped_too_large: 0}
```

Each method takes `enabled:` and `ttl_ms:`: `list_tools`, `list_resources`,
`list_prompts`, `read_resource`, `get_prompt`, and `call_tool`, which also
takes `included_tools:` and `excluded_tools:`. When the server's components of
a kind change while it runs, through the
[component manager](dynamic-components.md), visibility rules, or
`FastestMCP.notify_list_changed/2`, the cache drops what it kept of that kind:
a new tool drops the tool list and the tool results, but not the prompts.
`cache_statistics/1` returns the counters of each method.

### Errors and retries

`error_handling/1` logs every failed request, at the level the error asks for
(`log_level:` of `FastestMCP.Error`, `:error` by default), counts the failures,
and calls `error_callback:` with each one, for example to report it to your
error tracker. A failure is named by the exception a handler or middleware
raised, or else by the `FastestMCP.Error`. `error_counts/1` returns the counts
by exception and method:

```elixir
errors = FastestMCP.Middleware.error_handling(logger: fn _level, _message -> :ok end)

FastestMCP.server("middleware-errors")
|> FastestMCP.add_middleware(errors)
|> FastestMCP.add_tool("export_notes", fn _args, _ctx -> raise "the disk is full" end)
|> FastestMCP.start_server!()

{:error, _error} = FastestMCP.call_tool("middleware-errors", "export_notes")

FastestMCP.Middleware.error_counts(errors)
# => %{"RuntimeError:tools/call" => 1}
```

`retry/1` runs the rest of the chain again when it fails with one of
`retry_codes:` (default `[:timeout]`), up to `max_retries:` (default 3) more
times, waiting `base_delay:` seconds (default 1), then twice as long each
time. A retry runs the handler again, so use it only for work that is safe to
repeat, and add it after the middleware that should see one request rather
than each attempt.

### Limiting result size

`response_limiting/1` cuts a tool result that would be larger than `max_size:`
bytes as JSON (default 1,000,000) and ends the text with
`"\n\n[Response truncated due to size limit]"`, or your `truncation_suffix:`.
`tools:` limits it to some tools:

```elixir
FastestMCP.server("middleware-limit")
|> FastestMCP.add_middleware(FastestMCP.Middleware.response_limiting(max_size: 200))
|> FastestMCP.add_tool("export_notes", fn _args, _ctx -> String.duplicate("note ", 100) end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "middleware-limit"})
[%{"text" => text}] = FastestMCP.Client.call_tool!(client, "export_notes", %{}).content

String.ends_with?(text, "[Response truncated due to size limit]")
# => true
```

### Tools for tool-only clients

Some clients can call tools but can't read resources or use prompts.
`prompt_tools/1` adds the tools `list_prompts` and `get_prompt`, which takes
`name` and `arguments`; `resource_tools/1` adds `list_resources` and
`read_resource`, which takes `uri`. The lists describe each prompt, resource,
and resource template as `prompts/list`, `resources/list`, and
`resources/templates/list` do, under `"prompts"`, `"resources"`, and
`"resourceTemplates"`. The tools run with the caller's identity, so
authorization and visibility apply as usual:

```elixir
FastestMCP.server("middleware-tool-only")
|> FastestMCP.add_middleware(FastestMCP.Middleware.prompt_tools())
|> FastestMCP.add_middleware(FastestMCP.Middleware.resource_tools())
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
  %{id: id, title: "Release"}
end)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("middleware-tool-only") |> Enum.map(& &1.name)
# => ["list_prompts", "get_prompt", "list_resources", "read_resource", "search_notes"]

FastestMCP.call_tool!("middleware-tool-only", "read_resource", %{"uri" => "notes://1"})
# => %{"result" => %{id: "1", title: "Release"}}
```

`tool_injection/2` adds tools of your own the same way, as
`{name, handler, options}` tuples. Injected tools come before the server's
tools and replace a tool of the same name. For a large catalog, see
[Bounded tool search](tools.md#bounded-tool-search).

### Session pings

`ping/1` checks that the clients of `2025-11-25` sessions still answer, with
the keepalive pings that MCP describes. Every `interval_ms:` (default 30
seconds), it sends an MCP `ping` request to the client of each session that has
made a request and listens for the server's messages: over HTTP while the
client keeps the session's `GET` event stream open, and over stdio. A client
that doesn't answer within `timeout_ms:` (default 10 seconds) fails that ping,
which changes nothing else: the session goes on, and so do the pings.

Each ping emits the telemetry event `[:fastest_mcp, :session, :ping]`, whose
`:result` is `:ok`, `:timeout`, or `:error`; attach a handler to the event to
act on clients that stopped answering. A session without a stream to the
client isn't pinged until its next request. `ping_sessions/1` returns the
`{server_name, session_id}` pairs it follows.

## Writing middleware

A middleware is a function of the operation and `next`. Calling
`next.(operation)` runs the rest of the chain and returns `{:ok, operation}`,
with the result in `operation.result`, or `{:error, %FastestMCP.Error{}}`. The
middleware returns the same shape. To answer without the handler, return an
error, or `{:ok, operation}` with a result of your own:

```elixir
read_only = fn
  %{method: "tools/call", target: target}, _next when target in ["add_note", "delete_note"] ->
    {:error, %FastestMCP.Error{code: :forbidden, message: "notes are read-only today"}}

  operation, next ->
    next.(operation)
end

FastestMCP.server("middleware-read-only")
|> FastestMCP.add_middleware(read_only)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_tool("add_note", fn _args, _ctx -> %{id: "3"} end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("middleware-read-only", "search_notes")
# => %{notes: []}

{:error, error} = FastestMCP.call_tool("middleware-read-only", "add_note")
{error.code, error.message}
# => {:forbidden, "notes are read-only today"}
```

The operation describes the request: `operation.method` is the MCP method,
such as `"tools/call"` or `"tools/list"`; `operation.target` the tool or
prompt name, or the resource URI; `operation.arguments` the arguments as the
caller sent them; and `operation.context` the
[handler context](context.md), with the caller's identity in
`operation.context.principal`. [What middleware receives](#what-middleware-receives)
lists the rest.

### Changing results

To change a result on the way back, match the `{:ok, operation}` that `next`
returns. This middleware removes authors' email addresses from tool results:

```elixir
defmodule NotesDemo.Redact do
  # Removes the author's email address from a result.
  def redact(%{email: _email} = result), do: Map.delete(result, :email)
  def redact(result), do: result
end

redact_emails = fn operation, next ->
  with {:ok, done} <- next.(operation) do
    {:ok, %{done | result: NotesDemo.Redact.redact(done.result)}}
  end
end

FastestMCP.server("middleware-redact")
|> FastestMCP.add_middleware(redact_emails)
|> FastestMCP.add_tool("note_author", fn _args, _ctx ->
  %{name: "Ann", email: "ann@example.com"}
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("middleware-redact", "note_author")
# => %{name: "Ann"}
```

`FastestMCP.Middleware.map_result/2` does the same in one line:
`operation |> next.() |> FastestMCP.Middleware.map_result(&NotesDemo.Redact.redact/1)`.
A tool result that you change must still match the tool's output schema, if it
has one, or the call fails.

If a middleware raises `FastestMCP.Error`, the request fails with that error.
Any other exception, or a return value of another shape, fails it with
`:internal_error`.

### Middleware modules

A middleware can also be a struct whose module implements the
`FastestMCP.Middleware` behaviour, which suits middleware with options or
shared across servers:

```elixir
# lib/my_app/audit_middleware.ex
defmodule MyApp.AuditMiddleware do
  @behaviour FastestMCP.Middleware

  require Logger

  defstruct methods: ["tools/call"]

  @impl true
  def call(%__MODULE__{methods: methods}, operation, next) do
    result = next.(operation)

    if operation.method in methods do
      outcome =
        case result do
          {:ok, _done} -> "ok"
          {:error, error} -> error.code
        end

      Logger.info(
        "MCP #{operation.method} #{operation.target} by " <>
          "#{inspect(operation.context.principal)}: #{outcome}"
      )
    end

    result
  end
end
```

Add it like any other: `FastestMCP.add_middleware(server, %MyApp.AuditMiddleware{})`.

### Stateful middleware

Middleware that keeps state between requests also implements
`c:FastestMCP.Middleware.child_spec/1`. Every server that uses the middleware
starts that child under its own supervisor when it starts, and stops it with
the server. The server then calls the middleware with its `:runtime` field set
to the child's pid. This middleware limits how many tools each user can call
while the server runs:

```elixir
# lib/my_app/call_quota.ex
defmodule MyApp.CallQuota do
  @behaviour FastestMCP.Middleware

  defstruct limit: 1_000, runtime: nil

  @impl true
  def child_spec(%__MODULE__{}), do: {Agent, fn -> %{} end}

  @impl true
  def call(%__MODULE__{} = quota, %{method: "tools/call"} = operation, next) do
    user = operation.context.principal

    used =
      Agent.get_and_update(quota.runtime, fn calls ->
        {Map.get(calls, user, 0), Map.update(calls, user, 1, &(&1 + 1))}
      end)

    if used < quota.limit do
      next.(operation)
    else
      message = "you have used your #{quota.limit} calls"
      {:error, %FastestMCP.Error{code: :rate_limited, message: message}}
    end
  end

  def call(%__MODULE__{}, operation, next), do: next.(operation)
end
```

```elixir
FastestMCP.server("middleware-quota")
|> FastestMCP.add_middleware(%MyApp.CallQuota{limit: 2})
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("middleware-quota", "search_notes")
FastestMCP.call_tool!("middleware-quota", "search_notes")

{:error, error} = FastestMCP.call_tool("middleware-quota", "search_notes")
error.message
# => "you have used your 2 calls"
```

The struct you add stays unchanged, so adding it to several servers gives
each server its own state, and the state starts over when the server
restarts. If the child process exits, the server restarts. To store the child
some other way than in `:runtime`, implement `c:FastestMCP.Middleware.attach/2`.

The built-in rate limiters, response caching, error handling, and pings work
this way. Their inspection functions, `FastestMCP.Middleware.cache_statistics/1`,
`FastestMCP.Middleware.error_counts/1`, and `FastestMCP.Middleware.ping_sessions/1`,
take the value you added and combine the state of every running server that
uses it.

## Middleware, providers, or transforms?

Three features change what a server does without touching handlers. Pick by
what you want to change:

| You want to | Use |
| --- | --- |
| Act on requests: log, limit, cache, retry, audit, block | Middleware |
| Offer components from elsewhere: another server, a remote server, an OpenAPI document, your database | A [provider](providers-and-mounting.md) |
| Change how components look: rename, namespace, rewrite descriptions, hide | A [transform](transforms.md) |
| Decide who may see and call a component | [Authorization](auth.md#authorizing-components) |
| Switch components on and off while the server runs | [Visibility rules](versioning-and-visibility.md) or [the component manager](dynamic-components.md) |

## Details

### What middleware receives

A `FastestMCP.Operation` has these fields for middleware:

| Field | Value |
| --- | --- |
| `method` | The MCP method, such as `"tools/call"`, `"resources/read"`, `"prompts/get"`, `"tools/list"`, `"resources/templates/list"`, `"completion/complete"`, `"initialize"`, `"ping"`, `"server/discover"`, `"subscriptions/listen"`, or an extension's method |
| `target` | The tool or prompt name, or the resource URI; `nil` for lists |
| `arguments` | The arguments, before validation; injected arguments are not there yet |
| `version` | The version the caller asked for, or `nil` |
| `context` | The request's `FastestMCP.Context`, after authentication |
| `transport` | `:streamable_http`, `:stdio`, `:in_process`, or `:background_task` |
| `task_request` | `true` when the caller asked to run the call as a task: in process with `task: true`, or with a `2025-11-25` task request |
| `component` | `nil` on the way in; on the way out, the component that ran |
| `result` | `nil` on the way in; on the way out, the result |

The result is:

- for a tool call, the handler's value after the conversions described in
  [Return values](tools.md#return-values), or its `FastestMCP.Tools.Result`;
  a `FastestMCP.BackgroundTask` handle when the call runs as a task;
- for a resource read, the handler's value, or a `FastestMCP.Resources.Result`;
- for a prompt, a `FastestMCP.Prompts.Result`;
- for a list, a list of maps that describe the components, with keys such as
  `:name` or `:uri`, `:version`, and `:tags`.

Except over HTTP, `ping` skips authentication, and so do `initialize` and
`server/discover` when they carry no credentials, so their
`operation.context.principal` may be `nil` even on a server that requires
credentials.

### Where middleware runs

Middleware runs in the process that handles the request, and the handler in a
supervised process of its own, so middleware doesn't see the handler's
[request state](context.md#request-state) or dependencies. A tool's timeout
covers the handler, not the middleware.

At runtime, the chain is your middleware in the order you added it, then the
tool interceptors of [server extensions](extensions.md#server-extensions),
then [tool search](tools.md#bounded-tool-search) when it is enabled. The
middleware of a mounted server runs inside the parent's chain, around calls of
that server's own components, and receives their names without the mount's
namespace.

A middleware that raises an exception other than `FastestMCP.Error` fails the
request with `:internal_error`, keeping the exception and its stacktrace in the
error's `:cause` for your logs. A return value that is neither `{:ok,
%FastestMCP.Operation{}}` nor `{:error, %FastestMCP.Error{}}` fails it with
`:internal_error` too.

### Built-in middleware in detail

- **Rate limiting.** Each limiter tracks at most `max_clients:` clients
  (default 10,000); when it is full and none of them is idle, a new client's
  request fails with `:overloaded`. `global_limit: true` makes every client
  share one limit even with `get_client_id:`.
- **Response caching.** The cache key holds the method, the target, the
  arguments, the requested version, the transport, whether the request came
  from a client or in process, the caller's identity, the session, if any, and
  how often the server's components of the method's kind changed, so a change
  moves on to new entries. Errors, tool results marked
  `is_error: true`, background tasks, and requests that answer an
  `InputRequiredResult` are never cached. An entry larger than `max_item_size:`
  (default 1,000,000 bytes) is skipped. Requests of an authenticated caller
  without a principal are not cached. Expired entries are removed every
  `cleanup_interval_ms:` (default 60,000).
- **Response limiting.** `max_size:` must be at least 39 bytes, the size of
  the smallest valid tool result, or the constructor raises `ArgumentError`.
  A cut result of a tool without an output schema is text only: its
  structured content is dropped. A tool with an output schema keeps its
  `structuredContent` and `isError`, and only the text is cut; when they
  alone exceed the limit, the call fails with `:internal_error`. An
  `InputRequiredResult` asks the client a question and is never cut.
- **Retry.** `retry_exceptions:` lists exception modules whose crashes are
  retried too; `max_delay:` (default 60 seconds) caps the wait, and
  `backoff_multiplier:` (default 2.0) sets its growth.
- **Error handling.** When a middleware raises, `error_handling/1` turns the
  exception into a clearer error: `ArgumentError`, `FunctionClauseError`, and
  `BadArityError` into `:invalid_params`, `KeyError` and a missing file into
  `:not_found`, and a file permission error into `:permission_denied`;
  `transform_errors: false` keeps the original. A handler that raises fails
  with `:component_crash`, which names the component and stays as it is.
  `include_traceback: true` adds the stack trace of the exception that a
  middleware or handler raised to the log. Errors are counted as
  `"ExceptionModule:method"`, by the exception they wrap.
- **Session pings.** The event's measurements hold `:system_time`, when the
  ping was sent, and `:duration`, and its metadata `:server_name`,
  `:session_id`, `:transport`, and `:result`. A session is followed from its
  first request that names a session id, and the next ping goes out
  `interval_ms:` after the previous one finished. While a ping waits for its
  answer, the session doesn't expire.

## See also

- [Observability](observability.md): request logs, telemetry, and tracing
- [Authentication and Authorization](auth.md): authentication, which runs
  before middleware
- [Providers and Mounting](providers-and-mounting.md) and
  [Transforms](transforms.md): the other ways to shape a server
- `FastestMCP.Middleware` and `FastestMCP.Operation`
