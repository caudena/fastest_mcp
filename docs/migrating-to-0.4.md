# Migrating to 0.4

0.4 is an unreleased breaking Elixir API update. MCP method names, negotiated
profiles, JSON-RPC envelopes, Plug integration, and handler contexts are
retained; the few wire-visible changes are listed under
[Wire changes](#wire-changes).

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

## Servers and components

### Handler results

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

Local calls normalize tool content with the same rules as the wire:
`FastestMCP.call_tool/4` returns `FastestMCP.Tools.Result` content as
string-keyed MCP content blocks such as `%{"type" => "text", "text" => "Hi"}`,
and a malformed content block fails local and wire calls with an
`:internal_error`. `structured_content` and `meta` keep the handler's keys.
`FastestMCP.ResultNormalizer` is removed.

### Builders and helpers

- Component options are validated per kind: an unknown option of
  `FastestMCP.add_tool/4`, `add_resource/4`, `add_resource_template/4`, or
  `add_prompt/4` raises `ArgumentError`; the "Component Options" section of
  `FastestMCP.Server` lists them.
- `FastestMCP.complete/4` reads references and arguments with string keys, as
  on the wire: `%{"type" => "ref/prompt", "name" => "greet"}`.
- `FastestMCP.Interact` no longer has `approve/3`; use
  `FastestMCP.Interact.confirm/3`.
- `FastestMCP.Auth` no longer has `new_many/1`; map `FastestMCP.Auth.new/2`
  over the providers.
- `FastestMCP.Root.parse/2` returns `{:error, :invalid_root_uri}` for a URI that
  is not valid UTF-8 instead of raising.
- `FastestMCP.Resources.HTTP.new/2` rejects unknown options, sends
  `accept: */*` unless you set an Accept header, and bounds each read with
  `timeout_ms:` (default 5 seconds) and `max_body_bytes:` (default 10 MiB). Its
  struct keeps request headers as a map of lowercase names, and a failed status
  is reported by code only.
- `FastestMCP.ComponentManager.add_tool/4` and the other add functions raise
  `ArgumentError` in the caller for a duplicate under `on_duplicate: :error`;
  the manager process no longer crashes and restarts the runtime.
- A `KeyError` raised inside a dependency resolver propagates as itself instead
  of being reported as an unknown dependency.

### Request contexts

`FastestMCP.Context.new/2` replaces `Context.build/2`. It takes the running
server's runtime snapshot instead of its name, raises for unknown options, and
has no side effects: it no longer starts the session of a session-scoped
context. Handlers receive ready contexts and are unaffected.

### Runtime and transports

- `FastestMCP.start_server/2` no longer accepts `max_global_event_subscribers:`;
  `max_event_subscribers_per_server:` and `max_event_subscriber_queue_len:`
  still bound event fanout.
- Streamable HTTP validates `stream_request_timeout_ms:` when the transport
  starts rather than on each request.
- A session's idle timeout restarts on any message it handles, and its share of
  the runtime quota is released when it terminates.
- A server that `FastestMCP.Transport.Stdio.serve/4` starts from a
  `%FastestMCP.Server{}` belongs to the connection: its output goes to stderr,
  and if its runtime exits, `serve/4` exits with `{:server_down, reason}`.
  Serving the name of a server that is not running raises `ArgumentError`.
- `FastestMCP.http_app/2` returns the plug `{FastestMCP.Transport.HTTPApp,
  opts}` instead of a function (which Bandit could not serve), validating the
  options when called. Give it to Bandit as `plug:`, or replace `app.(conn)`
  with `Plug.run(conn, [app])`.
- A schema's `validation_timeout_ms:` (in `schema_options:` or
  `FastestMCP.Schema.compile/2`) now bounds validation; it used to be ignored.

## Middleware

Remove constructor-generated `:middleware` closures and implement the
`FastestMCP.Middleware` behaviour; add the struct with
`FastestMCP.add_middleware/2`. Updating its fields updates dispatch
configuration, and two-argument middleware functions remain supported.

`next` now returns `{:ok, operation}` or `{:error, %FastestMCP.Error{}}`, and
middleware returns the same shape. Pass-through middleware is unchanged. A
result transformer reads `operation.result` (and `operation.component`) from
the operation `next` returns, a short-circuit returns
`{:ok, %{operation | result: value}}`, and error handling matches `{:error, error}`
instead of rescuing; an unexpected exception is in `error.cause`. Raising
`FastestMCP.Error` still fails the operation:

```elixir
defmodule MyApp.Redact do
  @behaviour FastestMCP.Middleware
  defstruct []

  @impl true
  def call(_config, %{method: "tools/call", target: "status"} = operation, _next),
    do: {:ok, %{operation | result: %{"status" => "maintenance"}}}

  def call(_config, operation, next) do
    with {:ok, done} <- next.(operation) do
      {:ok, %{done | result: redact(done.result)}}
    end
  end
end
```

`FastestMCP.Middleware.map_result/2` applies a function to a successful result.

Stateful middleware implements `c:FastestMCP.Middleware.child_spec/1` (and
optionally `c:FastestMCP.Middleware.attach/2`) instead of `activate_runtime/1`
and `deactivate_runtime/1`. Each server starts that state under its own
supervisor and stops it after the server's lifespan cleanup, so sharing a
configuration across servers does not share state. The built-in stateful
middleware keep their state handle in a `:runtime` field (rate limiting keeps
its algorithm in `:limiter`) and no longer have `close/1`. Calling a stateful
middleware outside a server returns an `:internal_error`; a test that calls one
directly starts its child spec (for example with `start_supervised!/1`) and
attaches the pid as `attach/2` does.

The built-in middleware changed with it:

- `FastestMCP.Middleware.SlidingWindowRateLimiting` and
  `FastestMCP.Middleware.DetailedTiming` are gone;
  `FastestMCP.Middleware.sliding_window_rate_limiting/1` and
  `FastestMCP.Middleware.detailed_timing/1` build rate limiting and timing
  (`label: :detailed`) configurations.
- `FastestMCP.Middleware.error_handling/1` with `transform_errors: false`
  returns the error unchanged.
- `FastestMCP.Middleware.response_caching/1` collection settings take atom
  keys.
- The inspection functions are on `FastestMCP.Middleware`:
  `FastestMCP.Middleware.cache_statistics/1` (was
  `Middleware.ResponseCaching.statistics/1`),
  `FastestMCP.Middleware.error_counts/1` (was
  `Middleware.ErrorHandling.get_error_stats/1`), and
  `FastestMCP.Middleware.ping_sessions/1` (was
  `Middleware.Ping.active_sessions/1`).

## Providers, mounts, and transforms

A custom provider is a struct whose module calls `use FastestMCP.Provider` and
implements `c:FastestMCP.Provider.list_components/3`; the other callbacks have
overridable defaults:

```elixir
defmodule MyApp.CatalogProvider do
  use FastestMCP.Provider

  defstruct tools: []

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{tools: tools}, :tool, _operation), do: tools
  def list_components(%__MODULE__{}, _kind, _operation), do: []
end
```

- The lookup callbacks are `c:FastestMCP.Provider.get_component_candidates/4`
  and `c:FastestMCP.Provider.get_resource_target_candidates/3`, which return
  every matching version; `get_component/4` and `get_resource_target/3` are no
  longer callbacks.
- `c:FastestMCP.Provider.activate_runtime/1` returns `{:ok, provider}` or
  `{:error, reason}`.
- `c:FastestMCP.Provider.list_component_page/5` defaults to `nil`, which lists
  the provider with `list_components/3`.
- `FastestMCP.Provider` keeps the behaviour, its `use` defaults,
  `FastestMCP.Provider.new/1`, and `FastestMCP.Provider.add_transform/2`. The
  `%FastestMCP.Provider{}` wrapper lost its `callbacks` field, and the functions
  that called a wrapped provider (`list_components/3`, `list_component_page/5`,
  `required_extensions/1`, `http_routes/1`, `get_component/4`,
  `get_resource_target/3`, `type/1`, and `component_page_callback?/1`) are
  internal.

Build the components a custom provider returns with
`FastestMCP.Components.Tool.new/3`, `FastestMCP.Components.Resource.new/3`,
`FastestMCP.Components.ResourceTemplate.new/3`, or
`FastestMCP.Components.Prompt.new/3`; they take the options of
`FastestMCP.add_tool/4` and its siblings.

A provider transform is a struct whose module calls
`use FastestMCP.ProviderTransform` and overrides
`c:FastestMCP.ProviderTransform.transform_component/3` and/or
`c:FastestMCP.ProviderTransform.reverse_identifier/4`; transforms no longer
have their own struct or `new/1`. See [Transforms](transforms.md).

Mounts are a mounted-server provider plus a namespace transform:

- `FastestMCP.mount/3` accepts only `namespace:`, `include_tags:`, and
  `exclude_tags:`, raising `ArgumentError` for any other option; a blank
  namespace means none.
- The mounted-server provider no longer takes `:namespace`; wrap it with the
  namespace transform, as `mount/3` does.

Skills vendor modules are replaced by one function, and
`Providers.Skills.new/1` by `FastestMCP.Providers.SkillsDirectory.new/1`:

```elixir
# 0.3: FastestMCP.Providers.Skills.Claude.new(reload: true)
FastestMCP.Providers.Skills.vendor(:claude, reload: true)
```

`FastestMCP.ProviderTransforms.ToolTransform.new/1` raises `ArgumentError` for
a mapping without `:name`.

OpenAPI bodies with dynamic keys or whole-body constraints use a `body`
argument with collision-safe aliases, and request plans and validators are
prepared once. Provider-bundled extensions resolve at the root before startup
and execute once per root. See [providers and mounting](providers-and-mounting.md)
and [extensions](extensions.md) for those composition rules.

## Connected client

Connected tool calls always return `FastestMCP.Client.ToolResult`. Read
`.content`, `.structured_content`, `.meta`, and `.is_error` explicitly. `.raw`
preserves the complete validated wire response, including unknown fields. The
`.structured_content_present?` flag distinguishes absent content from JSON
null. Text is never implicitly parsed as JSON. A completed MCP `isError` result
remains `{:ok, %ToolResult{is_error: true}}`; operational failures use the error
tuple. Use `call_tool_task/4` for an explicit remote task handle, and
`start_tool_result/4` plus `FastestMCP.Client.ToolResultRequest.await/2` for a
cancellable terminal call. Handles belong to the process that created them;
connection replacement never replays an in-flight call.

### Options

`FastestMCP.Client.connect/2`, `start_link/1`, and `child_spec/1` validate
their options in the caller before any process starts. An unsupported target,
an unknown, duplicate, or invalid option, or an option the selected transport
cannot use (such as `oauth:` on stdio or `env:` in-process) raises
`ArgumentError` instead of returning `{:error, error}` or failing inside the
client process. `sse_reconnect:` and `stdio_restart:` reject unknown keys.
Operations reject unknown options, including the previously ignored
`page_size:`; page through lists with `cursor:` or the `list_all_*` helpers.

### Facade

`FastestMCP.Client` keeps its connection, request, list, tool, and task-listing
operations. The negotiated state is one `FastestMCP.Client.Info` struct, one
function replaces each family of setters, and an operation on a handle lives on
the handle's module. Bang variants follow the same renames.

| Removed | Use instead |
| --- | --- |
| `session_id/1`, `protocol_version/1`, `capabilities/1`, `initialize_result/1`, `discovery_result/1`, `session_stream_open?/1` | the fields of the `FastestMCP.Client.Info` returned by `FastestMCP.Client.info/1` |
| `set_sampling_handler/2`, `set_log_handler/2`, and the other per-handler setters | `FastestMCP.Client.set_handler/3` with the handler's `connect/2` option name: `set_handler(client, :log_handler, fun)` |
| `set_access_token/2`, `set_auth_input/2` | `FastestMCP.Client.set_auth/2` with `connect/2` auth options: `set_auth(client, access_token: token)` |
| `Client.await/2`, `Client.cancel/2` | `FastestMCP.Client.Request.await/2`, `FastestMCP.Client.Request.cancel/2` |
| `await_tool_result/2`, `cancel_tool_result/2` | `FastestMCP.Client.ToolResultRequest.await/2`, `FastestMCP.Client.ToolResultRequest.cancel/2` |
| `fetch_task/3`, `refresh_task/3` | `FastestMCP.Client.Task.fetch/2` |
| `cached_task_status/2` | `FastestMCP.Client.Task.status/1` |
| `wait_for_task/3` | `FastestMCP.Client.Task.wait/2` |
| `task_result/3`, `remote_task_result/3` | `FastestMCP.Client.Task.result/2` |
| `cancel_task/3`, `cancel_remote_task/3` | `FastestMCP.Client.Task.cancel/2` |
| `update_task/4` | `FastestMCP.Client.Task.update/3` |
| `on_task_status_change/3` | `FastestMCP.Client.Task.on_status_change/2` |
| `report_progress/3`, `callback_cancelled?/1` | `FastestMCP.Client.CallbackContext.report_progress/3`, `FastestMCP.Client.CallbackContext.cancelled?/1` |
| `disconnect_with_evidence/1` | `FastestMCP.Client.disconnect/1`, which already succeeds only once the transport proves cleanup |
| `open_session_stream/2`, whose options were ignored | `FastestMCP.Client.open_session_stream/1` |
| `call_tool_result/4` on `FastestMCP.Client` and `FastestMCP.ClientGroup` | `call_tool/4` |
| `lifecycle_state/1`, `catalog_revision/1`, `catalog_snapshot/2`, `pin/1`, and their bang variants | no replacement: `FastestMCP.Client.ready?/1` and `FastestMCP.Client.info/1` report readiness and negotiated state, and every operation pins a named client itself |

A task function that took a task id now takes a handle; for an id, get one with
`{:ok, task} = FastestMCP.Client.track_task(client, task_id)`. On a legacy HTTP
connection, tracking a task opens the session stream (the old `fetch_task/3`
did not). A tool task's `FastestMCP.Client.Task.result/2` is a
`FastestMCP.Client.ToolResult` whose `.raw` is the payload `task_result/3`
returned; a handle tracked from an id returns that payload as is.

`set_auth/2` replaces every credential instead of merging: pass all of the
connection's auth options together, and `set_auth(client, [])` clears them.
`set_handler/3` raises `ArgumentError` for a key that is not a handler option.

### Behaviour

- Log, progress, notification, URL-elicitation-completion, and task-status
  handlers run outside the client process, one at a time in arrival order: a
  handler may call the client, and one that raises is logged.
- `initialize/3` and `request/4` params given with atom keys are converted to
  the wire's string keys and merged with the client's defaults, instead of
  being sent as duplicate keys.
- Over HTTP, `protocol_version: :auto` falls back to `2025-11-25` only on the
  HTTP status and JSON-RPC code the client itself recorded for the failed
  `server/discover`.
- A `subscriptions/listen` request the server rejects stops its request
  instead of leaving it running.

## Client groups

A named group registers its coordinator under the supplied name. Its supervisor
is a lifecycle handle. For an unnamed group, connect for an opaque handle:

```elixir
{:ok, group} = FastestMCP.ClientGroup.connect(clients: %{"reports" => [target: endpoint]})
{:ok, tools} = FastestMCP.ClientGroup.list_tools(group)
:ok = FastestMCP.ClientGroup.disconnect(group)
```

For an unnamed group already started under a supervisor, resolve its operation
handle once with `FastestMCP.ClientGroup.handle/1`. Named references follow OTP
replacement; opaque handles remain pinned. Borrowed clients are never stopped
with the group. All-page tool listing, calls, and group discovery share each
client's fresh catalog; per-call authentication overrides use isolated
discovery.

- Invalid options of an owned member raise `ArgumentError` before the group
  starts.
- `FastestMCP.ClientGroup.disconnect/1` of a stopped group returns `:ok`.
- Group operations, `start_link/1`, and `await_ready/2` accept `:infinity`
  timeouts (they raised before); `timeout_ms: 0` returns a timeout error, and
  `start_link/1` whose deadline has passed returns an error tuple.

## OAuth

`oauth:` options are validated with the other connection options: an invalid
value (for example an HTTP `authorization_server:` or a `redirect_uri:` without
a host) or an unknown key raises `ArgumentError` instead of making `connect/2`
return an `:unauthorized` error. `FastestMCP.Client.OAuth.start_link/1` takes a
keyword list, raises for unknown options, and still returns
`{:error, %FastestMCP.Client.OAuth.Error{stage: :configuration}}` for invalid
values.

`FastestMCP.Client.OAuth.authorization_header/3` waits at most its timeout
(5 s by default) instead of indefinitely; `authorize/3` and
`handle_unauthorized/4` take `timeout_ms:` (default `:infinity`).
`FastestMCP.Client.OAuth.clear/2` cancels the resource's running flow.
Failures that used to exit the caller are errors with stage `:authorization`:

| Reason | When |
| --- | --- |
| `:timeout` | the caller's timeout elapsed; the flow still completes and stores its token |
| `:cleared` | `clear/2` cancelled the flow the caller waited for |
| `:flow_crashed` | the flow's task crashed |
| `:unavailable` | the coordinator is not running or exited during the call |

Three reasons are more specific: a state mismatch is `:state_mismatch` (was
`:state_or_redirect_mismatch`, which now means only a redirect mismatch), a
redirect without a usable authorization code is `:authorization_code_required`
(was `:invalid_authorization_redirect`), and protected resource metadata
without authorization servers is `:authorization_servers_required` (was
`:resource_required`).

## Background tasks

A custom `FastestMCP.TaskBackend` is a set of functions over its own state
rather than a process. Replace `start_link/1` with `init/1`; writes return the
next state:

```elixir
@callback init(opts) :: {:ok, state} | {:error, reason}
@callback put_task(state, task) :: {:ok, state} | {:error, reason}
@callback fetch_task(state, task_id) :: {:ok, task} | {:error, :not_found | reason}
@callback delete_task(state, task_id) :: {:ok, state} | {:error, reason}
@callback list_tasks(state) :: {:ok, [task]} | {:error, reason}
```

`fetch_task` no longer receives scoping options and `list_tasks` no longer
pages: the task store applies session and owner scoping and pagination itself.
`expire_tasks/2` is gone; the store expires each finished task on a timer and
deletes it through `delete_task/2`. Task records are structs keyed by `:id`;
store and return them unchanged.

`FastestMCP.fetch_task/1` and the other local task functions return that task
struct. `FastestMCP.list_tasks/2` lists newest first and pages with the same
offset cursors as the other local list functions; cursors from 0.3 are invalid.

Remove `task_meta:` and `FastestMCP.TaskMeta`: pass `task: true` with
`task_ttl_ms:` instead. `FastestMCP.BackgroundTask` no longer has `await`,
`fetch`, and their bang variants; pass the handle to `FastestMCP.await_task/2`
or `FastestMCP.fetch_task/1`. `FastestMCP.Operation` no longer has a
`:task_supervisor` field.

Task status notifications forwarded by `FastestMCP.subscribe_task_notifications/3`,
and the `:notification` and `:related_task` maps of their events, use string
keys as on the wire: `notification["params"]["taskId"]`.

## Map keys

Options and metadata take atom keys, and maps shaped like the wire take string
keys; the runtime no longer tries both on every read:

- atom keys only: `FastestMCP.Auth.StaticToken` token configurations,
  `protected_resource:` and `FastestMCP.Auth.ProtectedResource.new/1`,
  `FastestMCP.PeerTask.new/1`, provider tool-transform rename configurations
  (`%{name: "short"}`), visibility `version:` selectors, server `metadata:`,
  `application_sessions:` (`allow_anonymous:`), the `:task_metadata` of
  `FastestMCP.Context.new/2`, tool metadata given to
  `FastestMCP.prepare_sampling_tools/2` (as `FastestMCP.list_tools/2` returns
  it), and `request_metadata:` (client info is `:clientInfo`; the
  `:client_info` alias is gone)
- string keys only, as the transports build it: auth input, including
  `"assigns"` (read by `FastestMCP.Auth.from_assign/2`), `"expected_resource"`,
  and `"expected_scopes"`
- a `FastestMCP.Error` sets its JSON-RPC code with the atom detail key
  `:jsonrpc_code`

A server definition's `metadata.capabilities` is always present, with the
string keys of the wire.

Values application code returns still take atom or string keys and are
normalized once: content blocks, the `from/1` result helpers, authenticator
results, prompt argument definitions, and completion results.
`FastestMCP.Protocol` no longer has `version/2`, which read metadata that
initialize ignores.

## Wire changes

- An operation whose process exits, a crashed stdio worker, and a non-`Error`
  exception in the transport engine are answered with a JSON-RPC internal
  error (instead of a crashed worker, no response on stdio, or a plain HTTP 500
  body).
- Elicitation and sampling requests relayed for a task carry related-task
  `_meta` without the always-null `"elicitation"` key.
- Progress notifications of a task that waits for input report
  `input_required` (was `working`).
- The `tasks/list` cursor of client callback tasks is an opaque offset cursor.
- Tool-search results describe a tool as `tools/list` does: with `execution`
  on 2025-11-25, and without the local `completion` keys of its input schema.
- A proxied resource read reports each content's own `mimeType` instead of the
  resource's declared type.

## Undocumented modules

Code that called modules outside the documented API (all under `FastestMCP.`)
should note:

- `Component.type/1` is `Component.kind/1`, and `Component.compare_versions/2`,
  `Component.version_key/1`, and `Component.highest_version/1` moved to an
  internal module.
- `FastestMCP.InputValidator`, `FastestMCP.CallSupervisor`,
  `FastestMCP.CallWorker`, and `FastestMCP.BackgroundTaskSupervisor` are gone.
- The retry middleware's `should_retry?/2` takes a `FastestMCP.Error`, and the
  `State` modules of the built-in middleware have no public functions.
- `Pagination` functions return tagged results.
- `Providers.Skills.Common` is internal and no longer has
  `relative_file_path/2`.
- Components built by providers have no `server_name`; `SamplingTool.from_tool/2`
  needs a `server_name:` option for them, which
  `FastestMCP.prepare_sampling_tools/2` passes.
