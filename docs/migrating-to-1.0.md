# Migrating to 1.0

1.0 is a breaking Elixir API update. MCP method names, negotiated profiles,
JSON-RPC envelopes, Plug integration, and handler contexts are retained. The
sections run from the changes most applications meet to the rare ones;
changes that only clients see are listed under [Wire changes](#wire-changes).

Upgrade your dependency requirement and lockfile together with the API
migration.

## Results and errors

Effectful client and local operations return tagged results, where they
returned the value and raised on failure; each has a raising bang variant.
Commands return `:ok` or `{:error, error}`. Pure builders still raise
argument-validation errors; `start_link/1`, `child_spec/1`, predicates, and
transport dispatch follow their existing conventions.

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

- Arguments that don't match a schema, and a missing required prompt
  argument, fail with `:invalid_params` instead of `:bad_request`, the code
  that `FastestMCP.Client` already used and JSON-RPC's `-32602` names. On the
  wire, `data.fastestmcp.code` is `"invalid_params"`; the JSON-RPC code stays
  `-32602`.
- A value without a JSON form, such as a stream or a PID, fails the call with
  `:internal_error`; in process a stream came back as a map of its fields, and
  over a transport the request failed without saying why.
- A resource handler's binary that isn't valid UTF-8 reaches clients as a
  blob, and an in-process read returns the bytes. It was base64 text: clients
  received it as text, or encoded a second time under a binary `mime_type:`.
- A tool with `output_schema:` may return an error result without
  `structured_content:`; it failed with `:internal_error`.
- A missing required property is reported at its own path, as
  `#/query a required property is missing`, and violation lists leave out
  the summary that `properties`, `items`, or `additionalProperties` added at
  the parent of a violation.
- A schema `$ref` that can't be resolved fails with
  `could not resolve JSON Schema reference "..."` instead of
  `could not compile JSON Schema`.

### Builders and helpers

- Component options are validated per kind: an unknown option of
  `FastestMCP.add_tool/4`, `add_resource/4`, `add_resource_template/4`, or
  `add_prompt/4` raises `ArgumentError`; the "Component Options" section of
  `FastestMCP.Server` lists them.
- A tool name must be 1 to 128 letters, digits, `_`, `-`, or `.`, and a
  resource's `audience`, `priority`, and `lastModified` annotations must hold
  the values MCP defines; anything else raises `ArgumentError` when you add
  the component.
- `mime_type:` has no default: a resource without it is listed without a type,
  and a read names the type of its value (`application/json`, `text/plain`, or
  `application/octet-stream`) instead of `application/json` for everything.
- `FastestMCP.complete/4` reads references and arguments with string keys, as
  on the wire: `%{"type" => "ref/prompt", "name" => "greet"}`.
- `FastestMCP.Interact` no longer has `approve/3`; use
  `FastestMCP.Interact.confirm/3`.
- `FastestMCP.Auth` no longer has `new_many/1`; map `FastestMCP.Auth.new/2`
  over the providers.
- `FastestMCP.Resources.HTTP.new/2` rejects unknown options, sends
  `accept: */*` unless you set an Accept header, and bounds each read with
  `timeout_ms:` (default 5 seconds) and `max_body_bytes:` (default 10 MiB),
  where it had neither limit. Its struct keeps request headers as a map of
  lowercase names, and a failed status is reported by code only.
- `FastestMCP.Resources.Directory.read/1` leaves the absolute `path` out of its
  entries and metadata, and the file and directory helpers' errors name the
  file or directory without its location on the server.
- `FastestMCP.Root.parse/2` returns `{:error, :invalid_root_uri}` for a URI that
  is not valid UTF-8 instead of raising.
- `FastestMCP.ComponentManager.add_tool/4` and the other add functions raise
  `ArgumentError` in the caller for a duplicate under `on_duplicate: :error`.
  The manager process crashed instead, so the call exited and the server's
  runtime restarted.
- A `KeyError` raised inside a dependency resolver propagates as itself instead
  of being reported as an unknown dependency.

### Runtime and transports

- `FastestMCP.start_server/2` raises `ArgumentError` for an invalid runtime
  option, for which it returned `{:error, %ArgumentError{}}`, and for an
  unknown one, which it ignored. A server module raises for its `runtime:`,
  `http:`, and `well_known_http:` options when its child spec is built.
- `FastestMCP.server/2` and the HTTP options (`FastestMCP.http_app/2`,
  `FastestMCP.streamable_http_child_spec/2`, `http:`, `forward`) raise
  `ArgumentError` for unknown keys, which they ignored; move a listener `ip:`
  into `bandit_options:`. A server module's own options still reach its
  `server/1`: `base_server/1` passes `FastestMCP.server/2` only the options it
  takes.
- `FastestMCP.Transport.WellKnownHTTP`, `FastestMCP.well_known_http_child_spec/2`,
  and `well_known_http:` reject unknown options too, including `path:`: the
  metadata route compares only the origin of a request with the resource, and
  the endpoint takes its path from the `forward`, so OAuth under a router prefix
  needs no `path:`.
- `use FastestMCP.ServerModule` defines `init/1` and `call/2`, which make the
  module the plug of its endpoint: `forward "/mcp", MyApp.MCPServer` can
  replace a `forward` to `FastestMCP.Transport.HTTPApp` with
  `server_name: MyApp.MCPServer`. A module that defines either function keeps
  its own.
- `use FastestMCP.ServerModule` also defines `serve_stdio/1`: a launch command
  such as `mix run --no-start -e "MyApp.MCPServer.serve_stdio()"` or a
  release's `eval` replaces a function of your own that started your
  application and called `FastestMCP.Transport.Stdio.serve/4`. Its
  `auth_input:` option gives a server with an authenticator the input of every
  stdio request.
- `FastestMCP.http_app/2` returns the plug `{FastestMCP.Transport.HTTPApp,
  opts}` instead of a function, which Bandit could not serve, and validates the
  options when called. Give it to Bandit as `plug:`, or replace `app.(conn)`
  with `Plug.run(conn, [app])`.
- `FastestMCP.start_server/2` no longer accepts `max_global_event_subscribers:`;
  `max_event_subscribers_per_server:` and `max_event_subscriber_queue_len:`
  still bound event fanout.
- Streamable HTTP validates `stream_request_timeout_ms:` when the transport
  starts rather than on each request.
- When the runtime of a server that `FastestMCP.Transport.Stdio.serve/4`
  started from a `%FastestMCP.Server{}` exits, `serve/4` exits with
  `{:server_down, reason}`; the runtime used to restart without the
  connection's session. Serving the name of a server that is not running
  raises `ArgumentError` with `stdio server ... is not running`.
- A process that a lifespan links to no longer restarts the server when it
  exits normally; a crash still does.
- Components and server-wide visibility rules changed at runtime survive the
  restart that follows a crash of the server's processes, other than the
  component manager; they were lost. `FastestMCP.stop_server/1` still discards
  them.
- The `signing_secret:` runtime option signs list cursors, and the request
  state of the multi-round-trip requests described under
  [Asking the client](#asking-the-client). With the same secret, every node and
  a restarted server accept a cursor, which failed with `invalid cursor`
  anywhere but on the runtime that issued it. Child specs and start arguments
  keep the secret wrapped, so supervisor reports leave it out.
- A schema's `validation_timeout_ms:` (in `schema_options:` or
  `FastestMCP.Schema.compile/2`) bounds validation; validation used the
  default of one second.

### Request contexts

`FastestMCP.Context.new/2` replaces `Context.build/2`. It takes the running
server's runtime snapshot instead of its name, returns the context instead of
`{:ok, context}`, raises for unknown options, and has no side effects: it no
longer starts the session of a session-scoped context. Handlers receive ready
contexts and are unaffected.

A request that names no session (every `2026-07-28` request and every
in-process call without `session_id:`) is request-scoped: it starts no session
process, its `ctx.session_id` is `nil`, and the state it sets stays in the
request. Such a request used to run in a throwaway session with a random id,
which no later request could reach and which lived until its idle timeout;
these sessions counted toward `max_sessions:`, so requests failed with
`:overloaded` once enough had piled up. `Context.new/2` without `:session_id`
builds a request-scoped context.

Without a session:

- `Context.send_notification/3` returns `{:error, :no_session}`; it returned
  `{:ok, %{queued: true}}` for a notification that no client received.
- `Context.log/4` returns `:filtered` in process; it returned `:ok` for a
  message that no client received. A `2026-07-28` request answered without a
  stream gets `:filtered` too (was `{:error, :request_stream_unavailable}` at
  the level the client asked for).
- `Context.report_progress/4` with a progress token but no stream returns
  `{:error, :missing_progress_token}` (was `{:error, :unknown_request}`).
- `Context.enable_components/2`, `disable_components/2`, and
  `reset_visibility/1` raise an `:internal_error` that says a `2025-11-25`
  session is needed; they changed only the throwaway session. So does
  `Context.list_peer_tasks/2`, which raised a capability error.

`FastestMCP.Context.request_meta/1` returns the client's `_meta` on every
transport; the `"jsonrpc_envelope"` in `Context.request_context(ctx).meta`
holds it over HTTP and stdio only.

### Authentication

- `Context.client_id/1` returns the client id that the authenticator verified,
  or `nil`; it fell back to the name a client reported for itself in
  `clientInfo`.
- Over HTTP, `ctx.authenticated` is `false` when the server has no
  authenticator (it was `true`), so response caching treats such requests as
  anonymous.
- `FastestMCP.Auth.from_assign/2` fails with `missing or invalid credentials`
  instead of a message that named the assign to clients.
- An authenticator that raises fails the request with an `:internal_error`
  whose `cause` holds the exception and whose details name only its module
  (`kind`). The exception's message, which can hold the auth input, no longer
  reaches clients under `reason`, and `mask_error_details: true` masks the
  error as `authentication failed`, which it didn't. One that throws or exits
  fails the same way, with the throw or exit wrapped in an `ErlangError` as the
  cause: in process the throw or exit escaped to the caller, over stdio the
  request got no response, and over HTTP Bandit answered an empty `500`.
- Authentication errors carry no `provider` in their details. A function
  authenticator that raises or returns a malformed result or an unexpected
  error fails with `authenticator failed` (was
  `authenticator FastestMCP.Auth.FunctionProvider failed`); a module
  authenticator keeps its module in the message, as in
  `authenticator MyApp.MCPAuthenticator failed`.
- In process and over stdio, the handshake (`initialize` or `server/discover`)
  authenticates only the credentials it carries. `server/discover` always
  authenticated, so a client without credentials failed it: over stdio
  `FastestMCP.Client` then connected on `2025-11-25`, and in process it didn't
  connect. `initialize` never authenticated, so its capabilities left out what
  only the caller could use. A client without credentials connects on
  `2026-07-28`, and its calls fail with `:unauthorized`. Over HTTP every request
  is authenticated, as before.
- Over stdio, the `auth_input:` of the connection (of `serve_stdio/1`,
  `FastestMCP.Transport.Stdio.serve/4`, `FastestMCP.stdio_dispatch/3`, or a
  client in process) wins over the keys a client sends in
  `_meta.fastestmcp.auth`, which overrode its keys of the same name.
- `inspect/1` of a `%FastestMCP.Auth{}`, and so of a server definition and the
  supervisor reports that print it, leaves out the authenticator's options,
  such as the tokens of `FastestMCP.Auth.StaticToken`.

### Asking the client

On `2026-07-28`, `FastestMCP.Context.elicit/4`, `sample/3`, `list_roots/2`, and
the `FastestMCP.Interact` and `FastestMCP.Sampling` helpers work in ordinary
requests, where they failed outside a background task. They ask through
multi-round-trip requests: the handler runs again from the start for each
answer. Move side effects after the questions, and drop the
`InputRequiredResult` and `task: true` workarounds you wrote for them. On the
wire, a question is an `input_required` result whose input requests are keyed
`fastestmcp-1`, `fastestmcp-2`, and so on, with a signed `requestState` that
starts with `fastestmcp-rounds:`.

- Where no client can be reached, such as a call in process, the helpers raise
  an `:internal_error` that starts with `the request has no client to ask` and
  says what works; they raised a `RuntimeError`, a capability error, or
  `<method> failed`.
- `ping_peer/2`, `elicit_url/4`, and `require_url_elicitation!/4` raise
  `:method_not_found` on `2026-07-28`, which has no ping from the server and no
  URL elicitation; they failed there with other errors.
- `task: true` outside a `2025-11-25` session raises `:bad_request`; it was
  checked only against the client's capabilities.
- `FastestMCP.complete_elicitation/3` returns `:ok` instead of
  `{:ok, elicitation}`.

## Connected client

`FastestMCP.Client.call_tool/4` returns
`{:ok, %FastestMCP.Client.ToolResult{}}`; it returned the structured content,
the text of a single text block decoded as JSON, or the raw result map. Read
`.content`, `.structured_content`, `.meta`, and `.is_error` explicitly. `.raw`
preserves the complete validated wire response, including unknown fields. The
`.structured_content_present?` flag distinguishes absent content from JSON
null. A completed MCP `isError` result remains
`{:ok, %ToolResult{is_error: true}}`; operational failures use the error tuple.

`call_tool/4` raises `ArgumentError` for a `task:` option, with which it
returned a remote task handle; `call_tool_task/4` returns one.
`call_tool_result/4` is removed: `call_tool/4` returns the same result, and
`start_tool_result/4` plus `FastestMCP.Client.ToolResultRequest.await/2` make a
cancellable call.

### Options

`FastestMCP.Client.connect/2`, `start_link/1`, and `child_spec/1` validate
their options in the caller before any process starts. An unsupported target,
an unknown, duplicate, or invalid option, or an option the selected transport
cannot use (such as `oauth:` on stdio or `env:` in process) raises
`ArgumentError`. Unknown options were ignored, and the others returned an
error or failed inside the client process, which also stopped a caller that
didn't trap exits. `sse_reconnect:` and `stdio_restart:` reject unknown keys.
Operations reject unknown options, including the ignored `page_size:`; page
through lists with `cursor:` or the `list_all_*` helpers.

Credentials a transport can't use raise `ArgumentError` in `connect/2`,
`set_auth/2`, and each operation: `access_token:`, `authorization:`, and
`headers:` in process (`connect/2` and each call failed with
`:invalid_params`, and `set_access_token/2` accepted them), any credential on
stdio without `legacy_stdio_auth_metadata: true` (dropped before), and stdio
options such as `env:` over HTTP (ignored before).

An operation's `timeout_ms:` defaults to the connection's `timeout_ms:` instead
of 5 seconds. A term that is not a client, a pid, or a name raises
`ArgumentError` instead of `FunctionClauseError`.

### Facade

`FastestMCP.Client` keeps its connection, request, list, tool, and task-listing
operations. The negotiated state is one `FastestMCP.Client.Info` struct, one
function replaces each family of setters, and an operation on a handle lives on
the handle's module.

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
| `lifecycle_state/1` | `FastestMCP.Client.ready?/1` and `FastestMCP.Client.info/1`, which report readiness and negotiated state |

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
  handler may call the client, and one that raises is logged. They ran inside
  the client process, which dropped what they raised.
- Maps you pass (arguments, raw params, references, `meta:`, the answers of
  sampling and elicitation handlers) are sent as JSON: string keys at every
  level, atoms as strings. Atom keys failed validation with `:invalid_params`.
  `initialize/3` and `request/4` params given with atom keys are merged with
  the client's defaults instead of being sent beside them as duplicate keys.
- `read_resource/3` returns the whole result, `%{"contents" => [...]}`. For a
  result with one content and no `_meta`, the common case on `2025-11-25`, it
  returned that content's text, decoded when JSON, or its blob. Read
  `result["contents"]`.
- A request that its owner cancels, or whose `await/2` times out, sends
  nothing more to the owner's mailbox, and
  `FastestMCP.Client.Request.await/2` then returns a `:cancelled` error; the
  cancellation used to arrive as a message. A `ToolResultRequest` whose
  `await/2` timed out sends nothing either.
- `call_tool_task/4` sends `task: [ttl_ms: ms]` on `2025-11-25`, where it asked
  for the server's default time to live. On `2026-07-28` it fails with
  `:bad_request` before it calls the tool unless both sides declare the Tasks
  extension; it ran the tool and then failed.
- On `2026-07-28` the client asks for log messages in each request's `_meta`
  (`io.modelcontextprotocol/logLevel`): `info` and above with a `log_handler:`,
  or the level of `set_log_level/3`, which failed there. Drop
  `meta: %{"io.modelcontextprotocol/logLevel" => ...}` from calls that only
  asked for logs.
- A client connected in process passes `auth_input:` to the server's
  authenticator as Elixir terms, beside each message, instead of as JSON in
  `_meta.fastestmcp.auth`, where a struct such as a `mix phx.gen.auth` scope
  failed the request. Its requests show the transport `:in_process` instead of
  `:stdio`.
- A call keeps using a tool list whose `ttlMs` ran out for the tools it lists,
  and lists again only for a tool it lacks; against a server that sends
  `ttlMs: 0`, as 0.3 servers do, it listed the tools before every call.
- With `protocol_version: :auto`, the client falls back to `2025-11-25` only on
  evidence of a legacy server. Over HTTP that is the HTTP status and JSON-RPC
  code the client recorded for the failed `server/discover`; it also took them
  from the error data the server sent. Over stdio it is an error response or an
  invalid one; any error, a timeout, or the program's exit selected
  `2025-11-25`. An authentication error (`:unauthorized` or `:forbidden`) is
  returned on every transport.
- A stdio program that exits while connecting reports its exit status
  (`stdio server exited with status 1`); it failed with
  `stdio client transport exited`, or with a `:noproc` exit under
  `protocol_version: :auto`.
- An HTTP error without a JSON-RPC body takes the code of its status
  (`:unauthorized` for `401`, `:forbidden` for `403`, `:not_found` for `404`,
  `:rate_limited` for `429`, `:overloaded` for `503`, `:timeout` for `504`), or
  of a FastestMCP endpoint's error body, with a clean message such as
  `server/discover failed with HTTP 404 Not Found`. Every `4xx` was
  `:bad_request`, and every `5xx` `:internal_error`.
- Connecting waits for an OAuth sign-in that is still under way when
  `init_timeout_ms:` runs out, then connects; it failed with `:timeout` and
  lost the token.
- `initialize/3` can be retried when its request failed. A missing OAuth
  `authorization_handler:` fails with `:authorization_handler_required` (was
  `:invalid_authorization_handler`).
- The start arguments of `FastestMCP.Client.child_spec/1` keep the values of
  credential options wrapped, so supervisor reports print them redacted.

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

  # Your redaction goes here.
  defp redact(result), do: result
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
- The inspection functions are on `FastestMCP.Middleware`:
  `FastestMCP.Middleware.cache_statistics/1` (was
  `Middleware.ResponseCaching.statistics/1`),
  `FastestMCP.Middleware.error_counts/1` (was
  `Middleware.ErrorHandling.get_error_stats/1`), and
  `FastestMCP.Middleware.ping_sessions/1` (was
  `Middleware.Ping.active_sessions/1`).
- `FastestMCP.Middleware.error_handling/1` logs, counts, and reports a
  handler's crash by the exception the handler raised: the count key is
  `"RuntimeError:tools/call"` (was `"FastestMCP.Error:tools/call"`), and
  `error_callback` receives that exception instead of the `FastestMCP.Error`
  that wrapped it. The error keeps the exception and its stack trace in
  `error.cause`.
- `FastestMCP.Middleware.ping/1` sends MCP `ping` requests to the clients of
  `2025-11-25` sessions that listen on a stream; it sent nothing. It takes
  `timeout_ms:` (default 10 seconds), and unknown options raise. Its
  `[:fastest_mcp, :session, :ping]` event follows each ping, with `duration`
  and `result` (`:ok`, `:timeout`, or `:error`), instead of each interval.
- `FastestMCP.Middleware.response_caching/1` drops what it kept of a kind of
  component when that kind changes (entries lasted until their TTL), and keeps
  the entries of each session apart, in process too. Its collection settings
  take atom keys.
- The `get_prompt` and `read_resource` tools of `prompt_tools/1` and
  `resource_tools/1` declare input schemas, so a call without `name` or `uri`
  fails with `:invalid_params` instead of crashing. `list_prompts` and
  `list_resources` return the descriptors of `prompts/list`, `resources/list`,
  and `resources/templates/list`, with the templates under
  `"resourceTemplates"` (they returned internal component maps, the templates
  under `"resource_templates"`).

## Providers, mounts, and transforms

A custom provider is a struct whose module calls `use FastestMCP.Provider` and
implements `c:FastestMCP.Provider.list_components/3`, where the runtime looked
for whichever provider functions the module exported; the other callbacks have
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

- A provider's `get_component/4` is no longer called: the lookup callbacks are
  `c:FastestMCP.Provider.get_component_candidates/4` and
  `c:FastestMCP.Provider.get_resource_target_candidates/3`, which return every
  matching version.
- `c:FastestMCP.Provider.activate_runtime/1` returns `{:ok, provider}` or
  `{:error, reason}`; a bare provider is no longer accepted.
- `c:FastestMCP.Provider.list_component_page/5` defaults to `nil`, which lists
  the provider with `list_components/3`.
- `FastestMCP.Provider` keeps the behaviour, its `use` defaults,
  `FastestMCP.Provider.new/1`, and `FastestMCP.Provider.add_transform/2`. The
  functions that called a wrapped provider (`list_components/3`,
  `list_component_page/5`, `http_routes/1`, `get_component/4`,
  `get_resource_target/3`, `type/1`, and `component_page_callback?/1`) are
  internal.
- A custom provider announces changes of its components with
  `FastestMCP.notify_list_changed/2`.
- When your definition, a provider, and the component manager have the same
  name and version, lists show it once, from the source a call runs; they
  showed every entry.

Build the components a custom provider returns with
`FastestMCP.Components.Tool.new/3`, `FastestMCP.Components.Resource.new/3`,
`FastestMCP.Components.ResourceTemplate.new/3`, or
`FastestMCP.Components.Prompt.new/3`; they take the options of
`FastestMCP.add_tool/4` and its siblings.

A provider transform is a struct whose module calls
`use FastestMCP.ProviderTransform` and overrides
`c:FastestMCP.ProviderTransform.transform_component/3` and/or
`c:FastestMCP.ProviderTransform.reverse_identifier/4`; `ProviderTransform.new/1`
and its dispatch functions are gone. See [Transforms](transforms.md).

- `FastestMCP.ProviderTransforms.ToolTransform.new/1` raises `ArgumentError`
  for a mapping without `:name`, which renamed the tool to `""`, and for a new
  name that isn't a valid tool name.
- A server transform that changes a tool's schemas has them compiled, as a
  provider transform does; calls were validated against the old schema.

Mounts are a mounted-server provider plus a namespace transform:

- `FastestMCP.mount/3` accepts only `namespace:`, `include_tags:`, and
  `exclude_tags:`, raising `ArgumentError` for any other option; a blank
  namespace means none.
- A namespace takes letters, digits, `_`, `-`, and `.` only, and one that makes
  a tool name longer than 128 characters raises `ArgumentError`.
- A mounted server's handlers resolve its own dependencies before the
  parent's; they used to see the parent's alone.
- A mounted server's handlers get the context of the server the client called:
  `ctx.server_name` names it (it named the mounted server), and session state,
  log messages, notifications, requests to the client, and per-session
  visibility work in them (they failed, for example with
  `{:error, :not_found}`). Their reads and calls through the context, such as
  `FastestMCP.Context.read_resource/2`, go to that server, by the names its
  clients see.
- The mounted-server provider no longer takes `:namespace`; wrap it with the
  namespace transform, as `mount/3` does.

Skills vendor modules are replaced by one function, and
`Providers.Skills.new/1` by `FastestMCP.Providers.SkillsDirectory.new/1`:

```elixir
# 0.3: FastestMCP.Providers.Skills.Claude.new(reload: true)
FastestMCP.Providers.Skills.vendor(:claude, reload: true)
```

OpenAPI:

- `FastestMCP.from_openapi/2` raises `ArgumentError` for an unknown option,
  which it ignored.
- An `operationId` with characters a tool name can't hold names its tool with
  `_` in their place, as in `repos_list-for-org`.
- A request body with dynamic keys, schema-local definitions, or constraints
  that can't become separate arguments is one `body` argument, with
  collision-safe aliases, and a body you supply must satisfy the operation's
  schema before FastestMCP sends the request; see
  [OpenAPI request fidelity](providers-and-mounting.md#openapi-request-fidelity).
- The new `headers:` option sends credentials such as an API key with every
  request, which needed a `requester:` that replaces the HTTP client.

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
deletes it through `delete_task/2`. Task records are `FastestMCP.TaskRecord`
structs keyed by `:id` instead of maps; store and return them unchanged.

`FastestMCP.fetch_task/1` and the other local task functions return a task
record instead of a map. `FastestMCP.list_tasks/2` pages with the same offset
cursors as the other local list functions; cursors from 0.3 are invalid.

A tool that a handler calls in process runs inline and returns its result, even
when the client negotiated tasks; on `2026-07-28`, with the Tasks extension on
both sides, the handler got a `FastestMCP.BackgroundTask` handle for a
task-capable tool. Pass `task: true` to start a background task; see
[Running tasks locally](background-tasks.md#running-tasks-locally).

- A task that waits for the answers of its `InputRequiredResult` fails with
  `:timeout` after the result's `timeout_ms:` (60 seconds); it waited until
  cancelled. A `2025-11-25` protocol task that returns one fails at once.
- On `2026-07-28`, a `:required` tool fails with `:method_not_found` on a
  server without the Tasks extension; it ran as an ordinary call.
- From a `2025-11-25` task, `roots/list`, `ping`, and URL-mode
  `elicitation/create` requests reach the client on a waiting `tasks/result`
  stream with related-task `_meta`, as elicitation and sampling do, and the
  task reports `input_required` meanwhile. They went to the stream of the
  request that created the task, which had often closed.
- `send_task_input/5` fails for a question other than an elicitation with a
  message that names `update_task/4` (was `background task is not waiting for
  input`).

Remove `task_meta:` and `FastestMCP.TaskMeta`: pass `task: true` with
`task_ttl_ms:` instead. `FastestMCP.BackgroundTask` no longer has `await/2` and
`fetch/1`; pass the handle to `FastestMCP.await_task/2` or
`FastestMCP.fetch_task/1`. `FastestMCP.Operation` no longer has a
`:task_supervisor` field.

Task status notifications forwarded by `FastestMCP.subscribe_task_notifications/3`,
and the `:notification` and `:related_task` maps of their events, use string
keys as on the wire: `notification["params"]["taskId"]`.

## Telemetry and tracing

- Over HTTP, authentication emits `[:fastest_mcp, :auth, :start]` and its
  `:stop` or `:exception` event, as in process and over stdio; it emitted none,
  even for a rejected request. The events carry the `request_id` of the
  operation the request runs.
- When the authenticator raised, threw, or exited,
  `[:fastest_mcp, :auth, :exception]` has `kind`, `reason` (the exception, an
  `ErlangError` for a throw or an exit), and `stacktrace`, and over HTTP the
  span current where the request arrived records the exception. An
  authenticator that throws or exits ends with this event; it had no end event.
- In process and over stdio, a list request runs the authenticator once, inside
  its operation, with the authentication events; it ran it a second time first,
  without events. The task methods (`tasks/get`, `tasks/list`, and the others)
  and an `initialize` that carries credentials emit the authentication events
  too.
- `[:fastest_mcp, :task, :progress]` is emitted in background tasks only (it
  followed every progress update, with a `nil` `task_id` outside tasks); other
  progress updates emit `[:fastest_mcp, :operation, :progress]`.
- The `data` of `[:fastest_mcp, :log, :message]` is the message as the client
  receives it, with sensitive keys redacted; it was the handler's data.
- `enduser.scope` holds the scopes the authenticator verified, or else the
  capabilities; it no longer reads the `scopes` of the `auth` map.
- The server span of a request whose handler raised records that exception
  and its stack trace, and `error.type` names its module, such as
  `RuntimeError` (was `FastestMCP.Error`).
- Over HTTP, a server span is a child of the span current in the process that
  received the request, such as the span of your HTTP instrumentation, unless
  the request names another trace in `_meta` or a `traceparent` header; it was
  a root span unless the request named a trace.

## OAuth

`oauth:` options are validated with the other connection options: an invalid
value (for example an HTTP `authorization_server:` or a `redirect_uri:` without
a host) or an unknown key raises `ArgumentError`. An unknown key was ignored,
and an invalid value stopped the client, and with it a caller that didn't trap
exits. `FastestMCP.Client.OAuth.start_link/1` raises for unknown options, which
it ignored, and returns
`{:error, %FastestMCP.Client.OAuth.Error{stage: :configuration}}` for invalid
values, which exited the caller.

`FastestMCP.Client.OAuth.authorization_header/3` waits at most its timeout
(5 s by default) instead of indefinitely; `authorize/3` and
`handle_unauthorized/4` take `timeout_ms:` (default `:infinity`).
`FastestMCP.Client.OAuth.clear/2` cancels the resource's running flow, which it
couldn't. The outcomes of a wait are errors with stage `:authorization`; a
crashed flow and a missing coordinator made the caller exit:

| Reason | When |
| --- | --- |
| `:timeout` | the caller's timeout elapsed; the flow still completes and stores its token |
| `:cleared` | `clear/2` cancelled the flow the caller waited for |
| `:flow_crashed` | the flow's task crashed |
| `:unavailable` | the coordinator is not running or exited during the call |

Three failures have one reason each: a state mismatch in a redirect URL is
`:state_mismatch` (was `:state_or_redirect_mismatch`, which now means a
redirect mismatch only), a redirect with an empty authorization code is
`:authorization_code_required`, like one without a code (was
`:invalid_authorization_redirect`), and protected resource metadata without
`authorization_servers` is `:authorization_servers_required`, like an empty
list (was `:resource_required`).

## Wire changes

Over HTTP:

- A request for an unknown or ended `2025-11-25` session gets `404` with a
  JSON-RPC error `Session not found` (code `-32001`) that names no request id
  (it had `unknown session "..."`, code `-32602`, and the request's id).
- A `2025-11-25` session request without `MCP-Protocol-Version` uses the
  version its session negotiated (it got `400`
  `MCP-Protocol-Version is required`).
- A `401` for a request without an `Authorization` header carries a challenge
  without an error: `Bearer`, or `Bearer resource_metadata="...", scope="..."`
  with protected resource metadata (both had `error="invalid_token"` and the
  authenticator's message).
- With protected resource metadata, a `403` carries an `insufficient_scope`
  challenge only when scopes are missing. Any other `403`, such as a request
  whose URL doesn't match the protected resource or an authenticator's own
  `{:error, :forbidden}`, gets no `WWW-Authenticate` challenge (it had an
  `insufficient_scope` one). A URL that doesn't match is also logged as a
  warning that names both URLs.
- A method other than `GET`, `POST`, and `DELETE` gets `405` with an `Allow`
  header, and another path `404`, both before authentication (they got `404`
  `unknown route`, or `401` on a route with an authenticator).
- A request for a server that isn't running gets `503` with `Retry-After: 1`
  and `server ... is not running` on every route of the server's HTTP endpoint
  (was `404` `unknown server ...`, which `2025-11-25` clients read as an ended
  session; extra `routes:` still answer), and at a
  `FastestMCP.Transport.WellKnownHTTP` metadata route (was `404`
  `unknown route`).
- A request body over 8 MB, the default of the new `max_body_bytes:` option,
  gets `413` with JSON-RPC code `-32600` and `"payload_too_large"` in
  `data.fastestmcp.code` (was `400` with `-32700` and `"parse_error"`).
- An internal error before the request runs, such as an authenticator that
  raised, gets `500`, and an authenticator's error with the code `:timeout`
  gets `504` (both were `400`).
- On `2026-07-28`, invalid parameters of an extension method are answered with
  `200` (was `400`), like every error of the operation itself.

In MCP messages:

- A request whose stdio worker crashed, and a non-`Error` exception in the
  transport engine over HTTP, are answered with a JSON-RPC internal error
  (instead of no response, or a plain HTTP `500` body).
- A component that is disabled, hidden from the caller's audience, or dropped
  by a server transform is answered as an unknown one (`not_found`, or
  `-32002` for a resource on `2025-11-25`), not with `disabled`,
  `not_visible`, or `filtered`.
- A server's capabilities always offer `tools`, `resources`, and `prompts`,
  with `listChanged` (and `subscribe` for resources on `2025-11-25`) where it
  can notify, even with no component of a kind; a kind without visible
  components was left out, so clients never learned of the first one added at
  runtime.
- On `2026-07-28`, the results of `tools/list`, `prompts/list`,
  `resources/list`, and `resources/templates/list` carry a `ttlMs` of `60000`
  (was `0`), as the server announces changes of its lists.
- A server module's `serverInfo` name is the module name without `Elixir.`,
  such as `"MyApp.MCPServer"`, and the default `serverInfo` and `clientInfo`
  version is FastestMCP's own (the fallback was `"0.2.0"`).
- `prompts/get` honours `_meta.fastestmcp.version`, which
  `FastestMCP.Client.render_prompt/4` sends for `version:`; both ignored it.
- A change of one session's visibility notifies only that session; a
  `2026-07-28` subscription received it too.
- Elicitation and sampling requests relayed for a task carry related-task
  `_meta` without the always-null `"elicitation"` key.
- Progress notifications of a task that waits for input report
  `input_required` (was `working`).
- The `tasks/list` cursor of client callback tasks is an opaque offset cursor.
- Tool-search results describe a tool as `tools/list` does: with `execution`
  on `2025-11-25`, and without the local `completion` keys of its input schema.
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
