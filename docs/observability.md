# Observability

FastestMCP reports what a running server does in three ways: request logs in
your application's log, `:telemetry` events for metrics, and OpenTelemetry spans
for distributed traces. All three cover HTTP, stdio, and in-process calls alike.
Messages that a handler sends to the client are something else; see
[Logging to the client](context.md#logging-to-the-client).

## Logging requests

`FastestMCP.Middleware.logging/1` logs a line when a request starts and another
when it ends:

```elixir
FastestMCP.server("logging-demo")
|> FastestMCP.add_middleware(FastestMCP.Middleware.logging())
|> FastestMCP.add_tool(
  "search_notes",
  fn %{"query" => query}, _ctx -> %{notes: [query]} end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
    "required" => ["query"]
  }
)
|> FastestMCP.add_tool("delete_note", fn _args, _ctx ->
  raise FastestMCP.Error, code: :forbidden, message: "notes are read-only"
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("logging-demo", "search_notes", %{"query" => "milk"})
# => %{notes: ["milk"]}

{:error, _forbidden} = FastestMCP.call_tool("logging-demo", "delete_note")
```

Your application's log shows:

```text
[info] event=request_start method=tools/call source=server
[info] event=request_success method=tools/call source=server duration_ms=0.41
[info] event=request_start method=tools/call source=server
[error] event=request_error method=tools/call source=server duration_ms=0.18 error=notes are read-only
```

A failed request is logged at the `:error` level, with the error's message. In a
server module, add the middleware in `server/1`, as in
[Adding middleware](middleware.md#adding-middleware). Middleware added earlier
wraps the middleware added after it, so add logging first to log the requests
that later middleware rejects too. Middleware runs after authentication, so a
request that fails authentication isn't logged.

### Choosing what to log

The lines name the MCP method, such as `tools/call`, but not the tool;
`include_payloads: true` adds the tool's name and arguments. `logging/1` takes
these options:

| Option | Default | Effect |
| --- | --- | --- |
| `:log_level` | `:info` | The level of the start and success lines. Failures are always logged at `:error`. |
| `:methods` | every method | Log only these methods, such as `["tools/call"]`. |
| `:include_payloads` | `false` | Add the request's payload to the start line: the tool or prompt name and the arguments, or the resource URI, as JSON. |
| `:max_payload_length` | `1_000` | Cut a logged payload to this many bytes, ending it with `...`; `nil` keeps it whole. |
| `:include_payload_length` | `false` | Add the payload's size in bytes. |
| `:estimate_payload_tokens` | `false` | Add a rough token count, the size divided by four. |
| `:payload_serializer` | JSON | A function that turns the payload map into a string. |
| `:structured_logging` | `false` | Log each line as a JSON object. |
| `:log_fn` | `Logger.log/2` | A function of the level and the message that writes the line. |

`FastestMCP.Middleware.structured_logging/1` is `logging/1` with
`structured_logging: true`. With `methods: ["tools/call"]` and
`include_payload_length: true`, it logs:

```text
[info] {"source":"server","method":"tools/call","event":"request_start","payload_length":54}
[info] {"source":"server","method":"tools/call","event":"request_success","duration_ms":0.1}
```

> #### Payloads contain arguments {: .warning}
>
> `include_payloads: true` writes every argument into your log as the client
> sent it, without redaction. Arguments can hold personal data or secrets, so
> enable it only where your log may hold them, and limit it with `:methods`.

These lines leave out results. To log what a client receives, write a
middleware around `FastestMCP.Operation.wire_result/1`; see
[Logging responses](middleware.md#logging-responses).

### One line per request

`FastestMCP.Middleware.detailed_timing/1` logs one line when a request ends,
naming the tool, resource, or prompt it called:

```elixir
FastestMCP.server("timing-demo")
|> FastestMCP.add_middleware(FastestMCP.Middleware.detailed_timing())
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("timing-demo", "search_notes")
FastestMCP.list_tools!("timing-demo")
{:error, _not_found} = FastestMCP.call_tool("timing-demo", "archive_note")
```

```text
[info] Tool 'search_notes' completed in 0.25ms
[info] List tools completed in 0.12ms
[info] Tool 'archive_note' failed after 0.04ms: unknown tool "archive_note"
```

`FastestMCP.Middleware.timing/1` names the method instead, as in
`Request tools/call completed in 0.3ms`. Its `label:` option takes a function
of the `FastestMCP.Operation`, such as
`fn operation -> "MCP #{operation.method} #{operation.target}" end`. Both take
`log_level:` (default `:info`, failures included) and `log_fn:`.

### When a handler crashes

FastestMCP doesn't write a log line of its own when a handler raises: the caller
receives the error. With the logging middleware, the `request_error` line
carries the error's message, such as
`tool "export_notes" crashed: could not reach the export service`. The
[telemetry](#telemetry-events) exception event carries the same message.

The error keeps the exception and its stack trace in its `:cause`, for your
logs and traces; clients never receive them. The
[span](#opentelemetry-tracing) of the request records them, and
`FastestMCP.Middleware.error_handling/1` logs and counts failures, with the
stack trace when you pass `include_traceback: true`:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_middleware(FastestMCP.Middleware.error_handling(include_traceback: true))

  # Then add your tools, resources, and prompts.
end
```

A tool whose handler raises then logs:

```text
[error] Error in tools/call: RuntimeError: could not reach the export service
** (RuntimeError) could not reach the export service
    (my_app 0.1.0) lib/my_app/mcp_server.ex:11: anonymous fn/2 in MyApp.MCPServer.server/1
    (fastest_mcp 1.0.1) lib/fastest_mcp/telemetry.ex:34: FastestMCP.Telemetry.with_context/2
    (fastest_mcp 1.0.1) lib/fastest_mcp/context.ex:262: FastestMCP.Context.with_request/2
    (fastest_mcp 1.0.1) lib/fastest_mcp/server_runtime/calls.ex:37: FastestMCP.ServerRuntime.Calls.run_task/2
    (elixir 1.20.4) lib/task/supervised.ex:105: Task.Supervised.invoke_mfa/2
    (elixir 1.20.4) lib/task/supervised.ex:40: Task.Supervised.reply/4
```

The middleware's other options are in [Middleware](middleware.md).

An authenticator that raises, throws, or exits fails the request before any
middleware runs, so `error_handling/1` doesn't log it. FastestMCP logs it
instead, with one `:error` line that names the authenticator, the exception's
module, and the stack trace, but not the exception's message or the arguments
in the stack trace, which can hold credentials; see
[Authenticating with a function](auth.md#authenticating-with-a-function). The
`[:fastest_mcp, :auth, :exception]` [event](#the-events) carries the whole
exception as `reason`, with its `stacktrace`, and the [span](#what-is-traced)
records it. Over HTTP, the client gets `500`.

## Telemetry events

FastestMCP emits [`:telemetry`](https://hexdocs.pm/telemetry) events for the
requests it runs, for background tasks, and for the log messages and progress
updates that handlers send. Attach a handler to turn them into metrics, logs,
or alerts.

### Attaching a handler

A handler is a function of the event name, its measurements, its metadata, and
the configuration you attach it with. Write it as a function of a module, and
attach it when your application starts. This one logs slow and failed requests:

```elixir
# lib/my_app/mcp_telemetry.ex
defmodule MyApp.MCPTelemetry do
  @moduledoc """
  Logs slow and failed MCP requests.
  """
  require Logger

  @events [[:fastest_mcp, :operation, :stop], [:fastest_mcp, :operation, :exception]]

  def attach do
    :telemetry.attach_many("my-app-mcp", @events, &__MODULE__.handle_event/4, %{slow_ms: 1_000})
  end

  def handle_event([:fastest_mcp, :operation, :stop], %{duration: duration}, metadata, config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    if ms >= config.slow_ms do
      Logger.warning("Slow MCP request #{metadata.method} #{inspect(metadata.target)}: #{ms} ms")
    end
  end

  def handle_event([:fastest_mcp, :operation, :exception], _measurements, metadata, _config) do
    Logger.warning("MCP #{metadata.method} failed with #{metadata.code}: #{metadata.error}")
  end
end
```

Call `MyApp.MCPTelemetry.attach()` at the start of `start/2` in
`lib/my_app/application.ex`. Handlers run in the process that emits the event,
so keep them fast, and send slow work to another process.

### Metrics in a Phoenix app

A Phoenix application defines its metrics in `lib/my_app_web/telemetry.ex`, and
LiveDashboard shows them. Add metrics built from FastestMCP's events to the list
that `metrics/0` returns:

```elixir
# In lib/my_app_web/telemetry.ex
def metrics do
  [
    # Keep the metrics Phoenix generated, and add:
    summary("fastest_mcp.operation.stop.duration",
      unit: {:native, :millisecond},
      tags: [:method]
    ),
    summary("fastest_mcp.tool.duration",
      event_name: [:fastest_mcp, :operation, :stop],
      measurement: :duration,
      unit: {:native, :millisecond},
      tags: [:target],
      keep: &(&1.method == "tools/call")
    ),
    counter("fastest_mcp.operation.exception.duration", tags: [:method, :code])
  ]
end
```

The first metric times each kind of request, the second each tool, and the
third counts failed requests by method and error code. Tag with `:target` only
where its values are few: for `resources/read`, it is the URI of each read.

### The events

The metadata of these events has the following keys:

| Key | Value |
| --- | --- |
| `:server_name` | The server's name, as a string |
| `:request_id` | FastestMCP's id for the request, the same as `ctx.request_id` |
| `:session_id` | The request's session id, as in `ctx.session_id`; `nil` on `2026-07-28` and for in-process calls without `session_id:` |
| `:transport` | `:streamable_http`, `:stdio`, `:in_process`, or `:background_task` |

Events from a background task also have `:task_id` and `:origin_request_id`,
the request that started the task.

| Event | Measurements | Other metadata |
| --- | --- | --- |
| `[:fastest_mcp, :operation, :start]` | `system_time` | `method`, `target`, `component_type` |
| `[:fastest_mcp, :operation, :stop]` | `duration` | `method`, `target`, `component_type` |
| `[:fastest_mcp, :operation, :exception]` | `duration` | `method`, `target`, `component_type`, `code`, `error` |
| `[:fastest_mcp, :auth, :start]` | `system_time` | `method`, `target`, `component_type`, `auth_provider` |
| `[:fastest_mcp, :auth, :stop]` | `duration` | `method`, `target`, `component_type`, `auth_provider` |
| `[:fastest_mcp, :auth, :exception]` | `duration` | `method`, `target`, `component_type`, `auth_provider`, `code`, `error`, and `kind`, `reason`, `stacktrace` when the authenticator raised, threw, or exited |
| `[:fastest_mcp, :task, :start]` | `system_time` | `task_id`, `origin_request_id` |
| `[:fastest_mcp, :task, :stop]` | `duration` | `task_id`, `origin_request_id` |
| `[:fastest_mcp, :task, :exception]` | `duration` | `task_id`, `origin_request_id`, `code`, `error` |
| `[:fastest_mcp, :task, :progress]` | `current`, `total`, `message`, `reported_at` | `task_id` |
| `[:fastest_mcp, :operation, :progress]` | `current`, `total`, `message`, `reported_at` | none |
| `[:fastest_mcp, :log, :message]` | `count` | `level`, `logger`, `data` |

- **Operation events** surround one request: a call, read, or list, a
  completion, or the `initialize`, `server/discover`, and `ping` requests.
  `method` is the MCP method, `target` the tool or prompt name or the resource
  URI (`nil` for a list), and `component_type` is `:tool`, `:resource`,
  `:prompt`, or `:server`. A failure has `code`, the `FastestMCP.Error` code
  such as `:not_found`, and `error`, its message.
- **Authentication events** surround the server's authenticator, for every
  request it authenticates. `auth_provider` names it, as in
  `"FastestMCP.Auth.StaticToken"`. Over HTTP, the transport authenticates each
  request, notifications included, before the request runs: `method` is the
  JSON-RPC method, or `nil` for a request without one, such as the `GET` of a
  `2025-11-25` session, and `target` and `component_type` are set for a call,
  read, or list. Their `request_id` is the operation's, the same as in its
  operation events and `ctx.request_id`. When the authenticator raised, the
  `:exception` event also has `kind` (`:error`), `reason` (the exception), and
  `stacktrace`, as `:telemetry.span/3` reports an exception. A throw or an exit
  is reported the same way, as the `ErlangError` that wraps it:
  `{:nocatch, value}` for a throw, `{:exit, reason}` for an exit.
- **Task events** surround a background task's handler; `:stop` means it
  returned and `:exception` that it failed. Their `request_id` is the task's own.
- **Progress events** follow every progress update that
  `FastestMCP.Context.report_progress/4` accepts: `[:fastest_mcp, :task, :progress]`
  in a background task, and `[:fastest_mcp, :operation, :progress]` in any
  other request. `total` and `message` are present when the handler gives them,
  and `reported_at` is in milliseconds since the Unix epoch.
- **`[:fastest_mcp, :log, :message]`** follows every message that
  `FastestMCP.Context.log/4` sends. `level` is a string such as `"info"`, and
  `data` is the message as the client receives it, with the values of
  sensitive keys replaced; see [Log delivery](context.md#log-delivery).

`duration` and `system_time` are in native time units; convert them with
`System.convert_time_unit/3`, or with `unit: {:native, :millisecond}` in a
metric. [Details](#event-details) lists further events.

### Testing telemetry

`:telemetry_test.attach_event_handlers/2` sends events to the test process:

```elixir
# test/my_app/mcp_telemetry_test.exs
defmodule MyApp.MCPTelemetryTest do
  use ExUnit.Case, async: true

  test "a tool call emits a stop event with its duration" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:fastest_mcp, :operation, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "milk"})

    assert_receive {[:fastest_mcp, :operation, :stop], ^ref, %{duration: duration},
                    %{method: "tools/call", target: "search_notes"}}

    assert duration > 0
  end
end
```

The handler receives the events of every process, including tests that run at
the same time. `assert_receive` waits for an event that matches the pattern and
leaves the others in the mailbox.

## OpenTelemetry tracing

FastestMCP creates OpenTelemetry spans for the requests a server serves and for
the operations of a `FastestMCP.Client`. When a FastestMCP client calls a
FastestMCP server, the server's span becomes a child of the client's span, so
one trace shows both sides.

### Setting up the SDK

FastestMCP calls the OpenTelemetry API, which does nothing until your
application includes the OpenTelemetry SDK. Add the SDK and the OTLP exporter:

```elixir
# In mix.exs
defp deps do
  [
    # The dependencies you already have, then:
    {:opentelemetry_exporter, "~> 1.10"},
    {:opentelemetry, "~> 1.7"}
  ]
end
```

Configure where the spans go. This sends them over OTLP to an OpenTelemetry
Collector, or to any backend that accepts OTLP over HTTP:

```elixir
# In config/runtime.exs
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: [service: [name: "my_app"]]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
```

The exporter also reads the standard `OTEL_EXPORTER_OTLP_ENDPOINT` and
`OTEL_SERVICE_NAME` environment variables. Without any configuration, the SDK
exports to `http://localhost:4318`, so turn exporting off in tests:

```elixir
# In config/test.exs
config :opentelemetry, traces_exporter: :none
```

To see spans in development without a collector, print them to the console with
`traces_exporter: {:otel_exporter_stdout, []}`.

The OpenTelemetry documentation recommends starting the exporter before the
SDK, and the SDK as a temporary application, so that a failure in the SDK
doesn't stop your release. Set that in your release:

```elixir
# In mix.exs
def project do
  [
    app: :my_app,
    # Keep your other project settings, and add:
    releases: [
      my_app: [applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]]
    ]
  ]
end
```

Then call a tool, and your tracing backend shows a span named
`tools/call search_notes`.

### What is traced

| Span | Kind | Created for |
| --- | --- | --- |
| `tools/call search_notes`, `prompts/get summarize_notes`, `tools/list`, `resources/read` | server | Every request that emits [operation events](#the-events), named after its method and its tool or prompt. A resource read is named `resources/read`, and its URI is an attribute. |
| `delegate search_notes` | internal | A call into a [mounted server](providers-and-mounting.md), between the span of the parent server and the span of the mounted one. |
| `tools/call search_notes`, `resources/read notes://1`, `tasks/get` and a task id | client | Every operation of a `FastestMCP.Client`, named after its method and its target. |

A failed request has a server span with the error status, an `exception`
event, and the attributes `error.type` and `fastestmcp.error.code`, the error
code, such as `component_crash`. When a handler or middleware raised, the event
records that exception with its stack trace, `error.type` names its module,
such as `RuntimeError`, and the status carries its message; otherwise they
describe the `FastestMCP.Error`. An HTTP request that fails authentication runs
no operation, so it has no server span; when the authenticator raised, the span
current where the request arrived, such as your HTTP instrumentation's, records
the exception in the same way. The client's span of a failed operation has
the error status and `error.type`. A tool result with `isError: true` is a
successful request on the server, and the client marks its span as failed,
with `error.type` set to `tool_error`.

### Trace context

A span continues the trace it receives:

- An in-process call, such as `FastestMCP.call_tool/4`, continues the current
  span of the calling process.
- A request over HTTP or stdio continues the trace named by the `traceparent`
  and `tracestate` in its `params._meta`. Over HTTP, the `traceparent` header
  counts too, and `_meta` wins when both are present. A request without either
  starts a new trace, unless a span is current, as below.
- `FastestMCP.Client` adds `traceparent` and `tracestate` to the `_meta` of each
  request, and keeps the `_meta` you pass.

So a call from a Phoenix controller, through a `FastestMCP.Client`, to another
FastestMCP server appears as one trace. HTTP instrumentation, such as
OpenTelemetry's instrumentation of Phoenix or Bandit, creates a span of its own
for the HTTP request, and the server span becomes its child: FastestMCP runs
the request with the trace context of the process that received it. A
`traceparent` in `_meta` that names another trace wins over that span.

### What spans contain

Server spans carry these attributes:

| Attribute | Value |
| --- | --- |
| `rpc.system`, `gen_ai.system` | `mcp` |
| `rpc.method`, `mcp.method.name`, `gen_ai.operation.name` | The MCP method |
| `rpc.service`, `mcp.server.name`, `fastestmcp.server.name` | The server's name |
| `fastestmcp.component.type` | `tool`, `resource`, `resource_template`, `prompt`, or `server` |
| `fastestmcp.component.key` | The component's key, such as `tool:search_notes@` |
| `mcp.resource.uri` | The URI of a `resources/read` |
| `mcp.session.id` | The request's session, if it has one |
| `fastestmcp.request.id` | FastestMCP's id for the request, as in telemetry metadata |
| `fastestmcp.transport` | `streamable_http`, `stdio`, `in_process`, or `background_task` |
| `enduser.id` | The `client_id` of the identity, or else the `sub` of its principal |
| `enduser.scope` | The scopes the authenticator verified, or else the identity's capabilities, separated by spaces |

Client spans carry `rpc.system`, `rpc.method`, `gen_ai.system`,
`gen_ai.operation.name`, `mcp.method.name`, `mcp.protocol.version`,
`mcp.server.name` (the name the server reports), `mcp.session.id`,
`fastestmcp.transport`, and `fastestmcp.component.target`, the tool, prompt,
URI, or task id. Attributes without a value are left out.

Spans never record arguments, results, content, request metadata, or HTTP
headers, so no token or credential reaches them that way. A failed span records
the error's message, which repeats whatever your code put into the exception, so
keep secrets out of exception messages. Some exceptions print the data they
failed on: a `KeyError` or `MatchError` on an authenticator's input prints the
input, with its `Authorization` header, so an authenticator should return
`{:error, :unauthorized}` for input it doesn't expect rather than raise.

## Details

### Event details

- `server_name` is a string. A server module's name is the module's, so
  `MyApp.MCPServer` appears as `"Elixir.MyApp.MCPServer"`, which
  `to_string(MyApp.MCPServer)` returns.
- `[:fastest_mcp, :operation, :start]` is emitted once the request is
  authenticated. An in-process call that fails authentication emits
  `[:fastest_mcp, :auth, :exception]` and `[:fastest_mcp, :operation, :exception]`
  without a start event. Over HTTP, a request that fails authentication emits
  only the authentication events, since it never runs. A request whose tool
  doesn't exist, or whose arguments don't match the input schema, emits a
  start and an exception event.
- `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe`, the
  `tasks/*` requests, and notifications emit no operation events. A tool that
  runs as a background task emits operation events for the `tools/call` that
  started it, and task events for its handler.
- A failed operation is one that returns an error. A tool result with
  `is_error: true` is a successful operation and emits a stop event.

These events are emitted as well, with at least the metadata listed:

| Event | Measurements | Metadata | When |
| --- | --- | --- | --- |
| `[:fastest_mcp, :resources, :updated]` | `count` | `uri` | `FastestMCP.notify_resource_updated/2` or `FastestMCP.Context.notify_resource_updated/2` ran. |
| `[:fastest_mcp, :components, :changed]` | `count` | `families`, such as `[:tools]`, and `session_id` for a change of one session's visibility | Components were added, removed, enabled, or disabled at runtime, or `FastestMCP.notify_list_changed/2` ran. |
| `[:fastest_mcp, :notifications, :tasks, :status]` | none | `task_id`, `status`, `session_id`, `request_id`, `origin_request_id`, `owner_fingerprint`, `notification`, `related_task` | A background task changed status. |
| `[:fastest_mcp, :resource_security, :rejected]` | `count` | `template`, `parameter`, `reason` | A resource template parameter failed the [template security](resources.md#template-security) checks. |
| `[:fastest_mcp, :session, :ping]` | `system_time`, `duration` | `server_name`, `session_id`, `transport`, `result` | A ping of the `FastestMCP.Middleware.ping/1` middleware finished; `result` is `:ok`, `:timeout`, or `:error`. |
| `[:fastest_mcp, :sse, :replay_reset]` | `count` | `server_name`, `session_id`, `reason` | A `2025-11-25` client asked to resume a stream from an event the server can't replay. |
| `[:fastest_mcp, :event, :drop]` | `sent_subscribers`, `dropped_subscribers`, `max_queue_len` | `server_name`, `event_suffix`, `reason` | A process that follows the server's events, such as the stream of a `2025-11-25` session, had too many messages waiting and missed an event; see [Limits and defaults](production.md#limits-and-defaults). |
| `[:fastest_mcp, :event, :subscriber_rejected]` | `limit` | `scope`, `reason` | A process could not follow the server's events, because too many already do. |
| `[:fastest_mcp, :client, :subscription, :protocol_error]` | `count` | `reason`, `subscription_id` | A `FastestMCP.Client` received an invalid `subscriptions/listen` stream. |

### Client spans

One client operation is one span for its whole life, even when it pages
through a list, polls a task, or continues a multi-round-trip request:

- Paging adds `mcp.pagination.page.count` and `mcp.pagination.item.count` to
  the operation's span instead of creating a span per page.
- Following a task adds `mcp.task.poll.count`, and an `mcp.task.status` event
  for each status the task reports. Answering a task's question creates a child
  span, `tasks/update` followed by the task id.
- Each further round of a multi-round-trip request creates a child span named
  `mcp.mrtr.continue`, followed by the method, with an `mcp.mrtr.round`
  attribute.
- A result served from the client's response cache still has a span, with
  `fastestmcp.cache.hit` set to `true`.

### Logs that FastestMCP writes

Without any middleware, FastestMCP logs:

- a warning for each HTTP request rejected by the
  [host check](transports.md#host-and-listener-safety), with the host and
  origins it received and the hosts it allows;
- a warning for each HTTP request whose URL isn't the configured protected
  resource, with both URLs; see [OAuth](phoenix.md#oauth);
- an error for each authenticator that raises, throws, exits, or returns
  something other than `{:ok, identity}` or `{:error, reason}`; see
  [When a handler crashes](#when-a-handler-crashes);
- a warning when a `2025-11-25` client reuses a request id in a session; see
  [Request ids](production.md#request-ids);
- a warning when a component replaces another of the same name, on a server
  created with `on_duplicate: :warn`;
- an error when a lifespan or dependency cleanup fails, or when a session's
  state can't be deleted from the store;
- an error when a `FastestMCP.Client` notification handler raises, and a
  warning when the client ignores a listed tool whose `"x-mcp-header"`
  annotations are invalid.

## See also

- [Middleware](middleware.md): the request pipeline and the other built-in
  middleware
- [Context](context.md): log messages and progress for the client
- [Production](production.md): limits, storage, and running several nodes
- [Troubleshooting](troubleshooting.md): common problems and their causes
