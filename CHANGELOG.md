# Changelog

## 1.0.0 - 2026-10-10

This is a breaking Elixir API release. Applications upgrading from 0.3.x should
follow [Migrating to 1.0](docs/migrating-to-1.0.md), which describes each
change and the code to update.

### Breaking changes

#### Results and handlers

- return tagged results from client and local operations, with raising bang
  variants; commands return `:ok` or `{:error, error}`
- treat plain handler maps as application data: `FastestMCP.Tools.Result`,
  `FastestMCP.Prompts.Result`, and `FastestMCP.Resources.Result` select MCP
  envelopes, and `FastestMCP.ResultNormalizer` is removed
- return local tool content as string-keyed MCP content blocks, normalized as
  on the wire
- fail invalid arguments, and a missing required prompt argument, with
  `:invalid_params` instead of `:bad_request`
- fail a call whose result has no JSON form, such as a stream or a PID, with
  `:internal_error`

#### Components

- validate component options per kind, raising `ArgumentError` for unknown
  ones
- check tool names, namespaces, tool renames, and resource annotations when
  they are defined
- drop the `application/json` default of `mime_type:`: a resource without it
  lists no type, and a read names the type of its value
- read the references and arguments of `FastestMCP.complete/4` with string keys
- remove `approve/3` from `FastestMCP.Interact` and `new_many/1` from
  `FastestMCP.Auth`
- bound `FastestMCP.Resources.HTTP` reads with `timeout_ms:` and
  `max_body_bytes:`, and reject its unknown options
- leave server paths out of `FastestMCP.Resources.Directory` listings and the
  file and directory helpers' errors

#### Runtime and transports

- raise `ArgumentError` from `FastestMCP.start_server/2` for unknown and
  invalid runtime options
- reject unknown keys in `FastestMCP.server/2`, the HTTP options, and the
  options of `FastestMCP.Transport.WellKnownHTTP`, which takes no `path:`
- validate a server module's `runtime:`, `http:`, and `well_known_http:` when
  its child spec is built
- return a `{FastestMCP.Transport.HTTPApp, opts}` plug from
  `FastestMCP.http_app/2`, which Bandit can serve
- remove `max_global_event_subscribers:`
- validate `stream_request_timeout_ms:` when Streamable HTTP starts
- end `FastestMCP.Transport.Stdio.serve/4` with `{:server_down, reason}` when
  the runtime of the server it started exits

#### Request contexts

- replace `Context.build/2` with `FastestMCP.Context.new/2`, which takes a
  runtime snapshot, returns the context, and starts no session
- start no session for a request that names none (every `2026-07-28` request,
  and in-process calls without `session_id:`): its `ctx.session_id` is `nil`
  and its state lasts for the request, so such requests no longer fill
  `max_sessions:` with throwaway sessions
- without a session, return `{:error, :no_session}` from
  `FastestMCP.Context.send_notification/3`, `:filtered` from `Context.log/4`,
  and `{:error, :missing_progress_token}` from `Context.report_progress/4`,
  and raise from the per-session visibility functions and
  `Context.list_peer_tasks/2`

#### Authentication

- never fall back to the name a client reported for itself in
  `FastestMCP.Context.client_id/1`
- set `ctx.authenticated` to `false` over HTTP when the server has no
  authenticator
- fail an authenticator that raises, throws, or exits with an internal error
  whose `cause` holds the exception; clients see only its kind, or
  `authentication failed` with `mask_error_details: true`
- name no internal module in authentication errors: they carry no `provider`
  detail, and a function authenticator's failure is `authenticator failed`
- fail `FastestMCP.Auth.from_assign/2` with `missing or invalid credentials`,
  which names no assign
- in process and over stdio, authenticate the handshake (`initialize` or
  `server/discover`) with the credentials it carries only, so a client without
  them connects on `2026-07-28`
- over stdio, prefer the connection's `auth_input:` to the keys a client sends
  in `_meta.fastestmcp.auth`

#### Asking the client

- raise an `:internal_error` that says what works from the helpers that ask
  the client when no client can be reached
- raise `:method_not_found` from `ping_peer/2` and URL elicitation on
  `2026-07-28`, and `:bad_request` for `task: true` outside a `2025-11-25`
  session
- return `:ok` from `FastestMCP.complete_elicitation/3`

#### Connected client

- return `{:ok, %FastestMCP.Client.ToolResult{}}` from `call_tool/4`, never
  decoded text or structured content alone, and remove `call_tool_result/4`
- raise `ArgumentError` for a `task:` option of `call_tool/4`; task handles
  come from `call_tool_task/4`
- validate client options in the caller, raising `ArgumentError` for invalid
  options and for options or credentials the transport can't use, in
  `set_auth/2` and per call too
- replace the getters with `FastestMCP.Client.info/1`, and the setters with
  `set_handler/3` and `set_auth/2`, which replaces every credential
- move request, task, and callback operations to their handle modules; task
  functions take a handle, which `track_task/3` makes from an id
- run handlers outside the client process, one at a time in arrival order
- default an operation's `timeout_ms:` to the connection's
- return the whole result from `read_resource/3`
- send nothing more to the owner of a request once it cancels the request or
  its `await/2` times out
- fail `call_tool_task/4` on `2026-07-28` before calling unless both sides
  declare the Tasks extension
- on `2026-07-28`, ask for log messages in each request's `_meta`: `info` and
  above with a `log_handler:`, or the level of `set_log_level/3`, which works
  there
- show handlers the transport `:in_process` for a client connected in process
- with `protocol_version: :auto`, return an authentication error from
  `server/discover`, and over stdio a timeout or the program's exit, instead of
  falling back to `2025-11-25`
- take the code of an HTTP error without a JSON-RPC body from its status, such
  as `:forbidden` for `403` and `:timeout` for `504`
- raise `ArgumentError` for a term that is not a client

#### Map keys

- take atom keys in options and metadata and string keys in wire-shaped maps,
  and remove `version/2` from `FastestMCP.Protocol`

#### Middleware

- return `{:ok, operation}` or `{:error, error}` from middleware and `next`
- keep the state of stateful middleware per server through `child_spec/1` and
  `attach/2`
- remove `FastestMCP.Middleware.SlidingWindowRateLimiting` and
  `FastestMCP.Middleware.DetailedTiming`: one rate-limiting and one timing
  implementation remain
- move the inspection functions to `FastestMCP.Middleware.cache_statistics/1`,
  `error_counts/1`, and `ping_sessions/1`
- log, count, and report a handler's crash in `error_handling/1` by the
  exception the handler raised
- send MCP `ping` requests from `FastestMCP.Middleware.ping/1`, and emit its
  `[:fastest_mcp, :session, :ping]` event after each ping, with its `result`
- return the descriptors of the MCP lists from the `list_prompts` and
  `list_resources` tools, with the templates under `"resourceTemplates"`
- take atom keys in the collection settings of `response_caching/1`

#### Providers, mounts, and transforms

- make `FastestMCP.Provider` and `FastestMCP.ProviderTransform` behaviours
  with `use` defaults, and make the provider dispatch functions internal
- replace the skills vendor modules with `FastestMCP.Providers.Skills.vendor/2`,
  and `Providers.Skills.new/1` with `FastestMCP.Providers.SkillsDirectory.new/1`
- reject unknown options in `FastestMCP.mount/3` and `FastestMCP.from_openapi/2`
- give a mounted server's handlers the context of the server the client
  called, so `ctx.server_name` names that server and its session works there
- take no `:namespace` in the mounted-server provider; `mount/3` wraps it in a
  namespace transform
- pass an OpenAPI body with dynamic keys, schema-local definitions, or
  constraints that cannot be flattened as one `body` argument (collision
  aliases still apply), and check a supplied partial body against the
  original schema before sending a request

#### Background tasks

- make `FastestMCP.TaskBackend` a state-passing behaviour
- return `FastestMCP.TaskRecord` structs from the local task functions, which
  page with offset cursors
- run a tool that a handler calls in process inline, even when the client
  negotiated tasks; `task: true` starts a background task
- fail a task that waits for the answers of an `InputRequiredResult` with
  `:timeout` after its `timeout_ms:` (60 seconds), and a `2025-11-25` protocol
  task that returns one at once
- on `2026-07-28`, fail a tool that requires a task on a server without the
  Tasks extension
- remove `task_meta:`, `FastestMCP.TaskMeta`, and the `FastestMCP.BackgroundTask`
  wrapper functions
- use string keys in task notification payloads

#### OAuth

- run discovery, token requests, and host callbacks in a task per resource;
  `authorization_header/3` waits at most its timeout, and `clear/2` cancels a
  running flow
- return failures as error reasons instead of exiting the caller
- report a state mismatch, a redirect without an authorization code, and
  metadata without authorization servers with one reason each
  (`:state_mismatch`, `:authorization_code_required`, and
  `:authorization_servers_required`), and a missing `authorization_handler:`
  with `:authorization_handler_required`
- validate `oauth:` options with the other connection options

#### Telemetry and tracing

- emit the authentication events over HTTP, for rejected requests too, with
  the `request_id` of the operation the request runs
- add the `kind`, `reason`, and `stacktrace` of an authenticator that raised,
  threw, or exited to `[:fastest_mcp, :auth, :exception]`
- record an authenticator's exception on the span current where an HTTP
  request arrived
- emit `[:fastest_mcp, :task, :progress]` in background tasks only, and
  `[:fastest_mcp, :operation, :progress]` for other progress
- put the message the client receives, redacted, in the `data` of
  `[:fastest_mcp, :log, :message]`
- read `enduser.scope` from the verified scopes
- name a crashed handler's exception in the `error.type` of its span

#### Wire

- answer a request whose stdio worker crashed, and a non-`Error` exception in
  the transport engine over HTTP, with a JSON-RPC internal error
- answer a component that is disabled, hidden from the caller, or filtered by
  a server transform as an unknown one
- carry a `ttlMs` of one minute in the `2026-07-28` results of the list methods
- name a server module in `serverInfo` without the `Elixir.` prefix
- default the `serverInfo` and `clientInfo` version to FastestMCP's own
  instead of falling back to `0.2.0` when its application isn't loaded
- drop the always-null `"elicitation"` key from the related-task `_meta` of
  relayed requests
- report `input_required` in the progress notifications of a task that waits
  for input
- page the client's callback-task `tasks/list` with opaque offset cursors
- challenge a `401` for a request without credentials with `Bearer` and no
  error
- answer a request URL that isn't the protected resource with a `403` without
  a challenge
- answer a method other than `GET`, `POST`, and `DELETE` with `405` and
  `Allow`, and another path with `404`, before authentication
- answer a request for a server that isn't running with `503` and
  `Retry-After` instead of `404`, on every route of the server's HTTP endpoint
  (its metadata route included; extra `routes:` still answer) and at a
  `FastestMCP.Transport.WellKnownHTTP` metadata route
- answer a request body over `max_body_bytes:` with `413` and JSON-RPC code
  `-32600` instead of `400` and `-32700`
- answer an internal error before a request runs, such as an authenticator
  that raised, with `500` instead of `400`, and an authenticator's `:timeout`
  error with `504`
- answer invalid extension parameters on `2026-07-28` with HTTP `200` instead
  of `400`, like every error of an operation

### New features

- add `FastestMCP.ClientGroup` for supervised, independently negotiated
  clients with namespaced discovery and cancellable routing
- add opt-in provider-bundled extensions with root conflict resolution and
  exactly-once root lifecycles
- on `2026-07-28`, let `FastestMCP.Context.elicit/4`, `sample/3`,
  `list_roots/2`, and the `FastestMCP.Interact` and `FastestMCP.Sampling`
  helpers ask the client from ordinary tool, prompt, and resource requests,
  through multi-round-trip requests with a signed request state; the handler
  runs again from the start for each answer
- serve a server module as the plug of its endpoint
  (`forward "/mcp", MyApp.MCPServer`), one `forward` per server, on Phoenix
  1.7 too
- add `serve_stdio/1` to server modules, which starts the module's application
  and serves it over stdio from `mix run --no-start` or a release's `eval`;
  its `auth_input:` gives an authenticator the input of every request
- answer the CORS preflight requests of the origins listed in the new `cors:`
  HTTP option
- take `{module, function, args}` for `allowed_hosts:`, `base_url:`, and the
  `cors:` origins, called on each request
- add the `max_body_bytes:` HTTP option, the size limit of a request body
  (8 MB by default)
- add the `signing_secret:` runtime option, which signs list cursors and the
  request state of multi-round-trip requests so that every node, and a
  restarted server, accepts them; supervisor reports leave the secret out
- add `FastestMCP.notify_list_changed/2`, with which a custom provider
  announces changes
- add `FastestMCP.Context.request_meta/1`, which returns the client's `_meta`
- add `headers:` to `FastestMCP.from_openapi/2`, sent with every request, for
  credentials such as an API key
- add `FastestMCP.Components.Tool.new/3` and its siblings, which build the
  components a custom provider returns
- add `FastestMCP.Middleware.map_result/2` for middleware that transforms a
  result

### Fixes

- keep the server running when a process that a lifespan links to exits
  normally
- keep the components and server-wide visibility rules changed at runtime
  across the restart that follows a crash of the server's processes
- raise a duplicate `FastestMCP.ComponentManager` add in the caller instead of
  crashing the manager and restarting the runtime
- resolve a mounted server's own dependencies before the parent's
- offer tools, resources, and prompts in every server's capabilities, so
  clients learn of the first one added at runtime
- notify only the session whose visibility changed, never `2026-07-28`
  subscriptions
- drop what response caching kept of a kind when that kind changes, and keep
  each session's entries apart, in process too
- list a name and version that several sources define once, from the source a
  call runs
- honour the requested version in `prompts/get`, which
  `FastestMCP.Client.render_prompt/4` sends for `version:`
- compile the schemas that a server transform changes
- bound validation with `validation_timeout_ms:` as documented
- report a missing required property at its own path, drop parent summaries
  and duplicates from violation lists, and name an unresolved `$ref`
- encode a binary that a resource handler returns as a base64 blob once
- return `{:error, :invalid_root_uri}` from `FastestMCP.Root.parse/2` for a URI
  that is not valid UTF-8 instead of raising
- let a `KeyError` raised inside a dependency resolver propagate instead of
  reporting an unknown dependency
- give the injected `get_prompt` and `read_resource` tools input schemas, so a
  call without `name` or `uri` fails with `:invalid_params`
- let a tool with an output schema return an error result without structured
  content
- keep the `mimeType` of each proxied resource content
- describe tools in tool-search results as `tools/list` does
- parse multiline and nested skill YAML without scalar coercion,
  Unicode-normalize search terms, and match URI literal percent triplets
  regardless of hex case
- preserve OpenAPI schema references and literal annotation data, validate
  complete request bodies, keep raw media and parameter examples, and send
  repeated multipart fields
- resolve tools for transport task results as calls do
- keep the updated Plug connection after reading a request body, so
  keep-alive framing survives split bodies
- avoid duplicate default HTTP headers
- replace line breaks in the default `WWW-Authenticate` error description
- check the protected resource against the forwarded path, so OAuth under a
  router prefix needs no `path:`
- return from stdio serving only after the last responses are written
- let escripts serve MCP, as the protocol schemas are compiled into the code
  instead of read from `priv` at runtime
- validate protocol messages without a process per message
- in process and over stdio, run the authenticator of a list request once
  instead of twice
- in process and over stdio, authenticate the `2026-07-28` task methods, so a
  server with an authenticator finds the tasks of its caller
- leave an authenticator's options, such as the tokens of
  `FastestMCP.Auth.StaticToken`, out of inspect output and supervisor reports
- keep a crashed handler's exception and stack trace in `error.cause`, for
  logs and spans but never for clients
- make a server span a child of the span current where the HTTP request
  arrived
- from a `2025-11-25` task, send roots, ping, and URL elicitation requests
  through `tasks/result` instead of the stream of the request that created
  the task, which had often closed
- name `update_task/4` in the error of `send_task_input/5` for a question it
  can't answer
- take `{name, function, options}` tools and functions in
  `FastestMCP.Sampling.run!/3` without preparing them
- send the time to live that `task: [ttl_ms: ms]` asks for from
  `FastestMCP.Client.call_tool_task/4`
- send maps with atom keys or atom values as JSON from the connected client,
  instead of failing validation
- pass an in-process client's `auth_input` to the authenticator as Elixir
  terms, so `FastestMCP.Auth.from_assign/2` works with structs such as
  `mix phx.gen.auth` scopes
- reuse a tool list past its `ttlMs` for the tools it lists, instead of
  listing before each call
- fetch a fresh status in `FastestMCP.Client.Task.result/2` after
  `FastestMCP.Client.Task.update/3` instead of answering the old questions
  again
- forward a call's `meta:` to the `tasks/get` and `tasks/update` requests of
  task waits and results
- default a non-positive peer poll interval instead of raising
- return `true` from `FastestMCP.Client.CallbackContext.cancelled?/1` once the
  client has stopped
- answer server requests without blocking the client
- stop the HTTP worker of a subscription stream that the client rejects
- wait for an OAuth sign-in that outlasts `init_timeout_ms:` while connecting
- let a client disconnect while an OAuth authorization is pending
- let a failed `initialize/3` be retried
- stop sending an access token after `set_auth(client, [])` clears it
- report the exit status of a stdio server that exits while connecting
- keep killing a stdio process group until it is gone
- leave credentials out of the crash reports of the client's processes and of
  the start arguments of its child specs

### Documentation

- reorganize the guides for newcomers, starting with a Phoenix tutorial
  (Getting Started) and Core Concepts; merged guides keep redirects:
  onboarding → getting-started, why-fastest-mcp and components → concepts,
  lifespan and dependency-injection → lifespans-and-dependencies,
  component-manager → dynamic-components, progress → context, logging and
  telemetry → observability, runtime-state-and-storage → production,
  phoenix-deployment → phoenix, and sampling-and-interaction →
  sampling-and-elicitation
- document the provider, provider-transform, component, progress, and
  elicitation-result modules that the guides use

### Verification

- add HTTP/stdio interoperability tests for both client and server roles

## 0.3.2 - 2026-08-28

### Connected client cancellation

- add `start_tool_result/4`, `await_tool_result/2`, and
  `cancel_tool_result/2` for cancellable terminal tool calls; the returned
  handle remains valid while `tools/call` transitions from its initial request
  into a server-owned remote task, and `call_tool_result/4` now uses the same
  shared execution path
- cancel an ordinary in-flight request directly, but preserve the race where a
  task-capable request may publish a remote task and cancel that task through
  `tasks/cancel` once its handle becomes available
- treat a tool request as task-capable only for MCP `2026-07-28` connections
  where the Tasks extension was negotiated by both peers; legacy connections
  and modern connections without Tasks now cancel the initial request instead
  of waiting indefinitely for an impossible task transition
- cancel outstanding work when its owning process exits or an await times out,
  while preserving the existing typed cancellation and protocol-error behavior

## 0.3.1 - 2026-08-16

### Compatibility fix

- stop rejecting `2025-11-25` client requests whose JSON-RPC id was already
  used by an earlier, finished request in the same session; the request is now
  served and one `Logger` warning names the request id, session id, and method.
  claude.ai (`Anthropic/ClaudeAI`, protocol `2025-06-18`) restarts its id
  numbering inside a live session after resuming a conversation and treats the
  `-32600 invalid_request` rejection as a tool failure without re-initializing,
  which left the connection permanently broken while authentication kept
  succeeding
- add the `strict_request_ids: true` runtime option to opt back into rejecting
  reused ids; the `max_request_ids:` capacity error, the in-flight duplicate
  check, and the sessionless `2026-07-28` path are unchanged

## 0.3.0 - 2026-08-14

### MCP `2026-07-28` and compatibility

- add MCP `2026-07-28` as the preferred modern profile while retaining full
  `2025-11-25` server and connected-client support at the same endpoint
- add `protocol_version: :auto | "2026-07-28" | "2025-11-25"` to the
  connected client; `:auto` probes modern discovery first and downgrades only
  on explicit legacy evidence
- expose newest-first supported-version and protocol-profile helpers, and
  include the official `2026-07-28` schema

### Extensions

- add the stable MCP Apps v1.0.0 metadata/resource boundary without
  implementing a browser Host, iframe renderer, sandbox, or `postMessage`
  bridge
- add the experimental `io.modelcontextprotocol/tasks` v2 wire for modern
  connections, including MRTR input and server-directed work, while keeping
  the distinct legacy Tasks v1 surface and including the draft extension
  schema
- add the draft OAuth Client Credentials and stable Enterprise-Managed
  Authorization connected-client grants through explicit host callbacks;
  FastestMCP remains a resource server/client toolkit, not an authorization
  server or identity provider
- add ordered modern active server extensions with negotiated request methods,
  parameter schemas, namespaced lifespans, and tool-call interceptors while
  keeping passive extension capability data separate

### Runtime state

- add application sessions on the existing session-state backend, including
  authenticated per-principal buckets, opaque explicit handles, termination,
  and an opt-in anonymous bearer mode
- add bounded request-scoped tool search with pinned list entries, deterministic
  ranking across tool and top-level public parameter metadata, provider
  pagination, model-visible policy enforcement, and a synthetic call path that
  revalidates the selected tool at execution time

### Authorization and resource safety

- carry verified OAuth scopes, audiences, authentication state, arguments, and
  resource-template captures through component authorization; scope checks now
  use verified token scopes while capability checks remain a separate explicit
  helper
- return `401` for missing or invalid authentication and a `403`
  `insufficient_scope` challenge with the exact missing scopes for verified
  tokens, while keeping opaque authorization denials generic
- screen decoded resource-template parameters for traversal, absolute paths,
  and null bytes by default after transforms and canonical rematching; rejected
  values remain indistinguishable from an unknown resource on the wire

### Connected client

- add OTP-supervised clients with `start_link/1`, explicit child specs, standard
  process naming, readiness checks, restart-safe pid pinning, and supervised
  ownership of request, callback, stream, and recovery workers
- add `call_tool_result/4` and `%FastestMCP.Client.ToolResult{}` as a stable,
  protocol-faithful terminal result while preserving the existing
  `call_tool/4` compatibility projection
- add connected-client OpenTelemetry spans and W3C propagation across HTTP,
  stdio, in-process calls, MRTR, Tasks, asynchronous lifecycles, pagination,
  cache hits, recovery, and cancellation without recording payloads or secrets
- make modern tool calls transparently drive server-created tasks while adding
  `call_tool_task/4` for explicit handles, a separate 60-second task deadline,
  adaptive polling, notification wakeups, and bounded MRTR interaction rounds
- add an opt-in bounded response cache for positive-TTL modern discovery,
  component-list, and resource-read results, with per-call use, refresh, and
  bypass controls plus authentication, roots, recovery, and notification
  invalidation
- add bounded `list_all_tools/2`, `list_all_prompts/2`,
  `list_all_resources/2`, and `list_all_resource_templates/2` helpers backed by
  one shared cursor-safe paginator
- add request-scoped `progress_handler:` callbacks with automatic progress
  tokens and task-lifetime routing through the existing progress subsystem
- add `Client.connect({:in_process, server_name}, opts)` through a supervised
  connected transport that preserves JSON-RPC, authentication, lifecycle,
  callback, progress, cancellation, task, and subscription behavior without
  bypassing the shared server engine

### Providers

- add a request-scoped HTTP and stdio proxy provider that mirrors or pins the
  protocol version, preserves modern results and MRTR continuations, forwards
  progress, and bounds upstream catalog pagination
- keep remote tasks, subscriptions, shared client pools, and credential
  forwarding out of the proxy default; HTTP authorization forwarding requires
  an exact trusted-origin allowlist; reject Proxy and bounded ToolSearch on the
  same server because opaque upstream cursors cannot provide a global
  synthetic-name collision proof within a bounded scan

### Verification and release gates

- update the official conformance runner to
  `@modelcontextprotocol/conformance@0.2.0-alpha.11`, run both frozen core
  requirement sets, and invoke supported Tasks and authorization-extension
  scenarios explicitly
- check that packaged schema and license files are present, and run the packaged
  consumer against both protocol revisions over HTTP and stdio

## 0.2.0 - 2026-08-12

This is a breaking protocol and lifecycle release. Applications upgrading from
0.1.x should review the migration notes below before deploying.

### MCP protocol and transport

- make MCP `2025-11-25` the sole negotiated protocol version; server metadata
  can add experimental capabilities but can no longer override the protocol
  version or standard capability shape
- accept MCP traffic only at the configured endpoint, `/mcp` by default, and
  remove the `/health`, trailing-slash redirect, and method-specific HTTP routes
  such as `/mcp/tools`, `/mcp/resources/read`, and `/mcp/tasks/*`; applications
  can provide their own health or non-MCP routes in the surrounding Plug router
- require JSON-RPC 2.0 envelopes and exactly one request, notification, or
  response per HTTP POST or stdio message; JSON-RPC batch arrays are no longer
  accepted
- require streamable HTTP POST requests to use `Content-Type:
  application/json` and advertise both `application/json` and
  `text/event-stream` in `Accept`
- return `202 Accepted` with no response body for JSON-RPC notifications
- run the official server conformance runner at
  `@modelcontextprotocol/conformance@0.1.16` as a release gate without
  expected-failure allowances

### Sessions and request lifecycle

- make stateful streamable HTTP sessions server-issued: `initialize` must not
  send `MCP-Session-Id`; the successful response supplies it, and subsequent
  requests must echo it
- enforce `initialize` followed by `notifications/initialized` before other
  requests, both for stateful HTTP sessions and each stdio connection
- require `MCP-Protocol-Version: 2025-11-25` on stateful HTTP requests after
  initialization, and reject unknown or terminated sessions
- remove zero-session HTTP and reject the former `stateless_http:` and
  `stateless:` options; use `state_scope: :request` for request-local handler
  state while retaining a normal server-issued MCP session
- add explicit context `state_scope`, negotiated protocol, client capability,
  and client information fields; request-scoped HTTP contexts keep their stable
  non-null session id
- remove the client's initial `session_id:` option and add `sampling_tools:`,
  `sampling_context:`, and a 1 MiB default `max_sse_event_bytes:` limit

### Task compatibility

- restrict standard remote task augmentation to `tools/call`; remote
  `prompts/get` and `resources/read` task extensions have been removed
- remove the non-standard wire method `tasks/sendInput` and the corresponding
  <code>FastestMCP.Client.send_task_input/5</code> API
- retain local in-process prompt/resource task creation and
  `FastestMCP.send_task_input/5` for Elixir-owned workflows
- normalize custom `FastestMCP.TaskBackend` callbacks: `fetch_task/3` returns
  `{:ok, task}` or `{:error, reason}`, and `expire_tasks/2` returns
  `{:ok, task_ids}` or `{:error, reason}`
- reconcile persisted active tasks in bounded pages when a runtime restarts and
  fail orphaned work with `:runtime_restarted`

### HTTP safety and public interfaces

- default HTTP listeners to loopback and `allowed_hosts: :localhost`
- forward listener configuration through `bandit_options:` and add a supervised
  streamed-request timeout through `stream_request_timeout_ms:` (60 seconds by
  default)
- remove `allowed_hosts: :any` and `unsafe_allow_any_host`; use a non-empty
  concrete host list for every non-loopback listener
- expose `FastestMCP.Auth.Result`, `FastestMCP.Auth.StaticToken`,
  `FastestMCP.TaskBackend`, and `FastestMCP.TaskBackend.Memory` in HexDocs
- source the ExDoc module filter and module groups from one shared public-module
  catalog so published docs cannot drift from the navigation groups
- authenticate every inbound HTTP message and control request, bind initialized
  sessions to the authenticated identity, and apply Host/Origin validation at
  the shared public Streamable HTTP entrypoint
- reject malformed, opaque, combined, and repeated Origin headers before
  authentication; accepted origins are serialized HTTP(S) origins whose host
  is present in `allowed_hosts`
- add optional RFC 9728 Protected Resource Metadata on the MCP resource origin,
  authoritative `resource_metadata`/`scope` bearer challenges, query-token
  rejection, and expected-resource/scope input for application authenticators
- add provider candidate callbacks for deterministic all-version resolution,
  including lower-version fallback after visibility or policy filtering
- centralize duplicate component policy and preserve `:warn` as
  warn-and-replace across server, local-provider, and component-manager
  registration
- correct middleware examples to use `max_requests_per_second:`,
  `max_requests:`/`window_minutes:`, and `max_size:`

### Schema, sampling, providers, and middleware

- add JSV `0.22.x` as the sole new runtime dependency and make
  `FastestMCP.Schema` the compile-once validation boundary for Draft 2020-12
  and Draft 7; validation is non-coercing, bounded, and redacted
- include the official MCP `2025-11-25` schema and cover
  the FastestMCP schema boundary with focused dialect, resolver, and limit tests
- apply a versioned compiled-view erratum for `NumberSchema.minimum`, `maximum`,
  and `default`: the TypeScript definitions and elicitation specification define
  numbers, while the published JSON schema emitted integers
- fail remote JSON Schema references closed by default; applications may opt in
  to an explicit resolver or the allowlisted HTTPS resolver with verified TLS,
  redirect refusal, and timeout/body limits
- canonicalize wire serialization around `_meta`, direct `resource_link`
  fields, object-only structured tool content, and resource templates listed
  exclusively by `resources/templates/list`; FastestMCP-only task elicitation
  state now lives under `_meta.fastestmcp`
- make component authorization fail closed: only `true` and `:ok` authorize;
  malformed returns, exceptions, throws, and exits deny access, while
  unversioned resolution may fall back from an unauthorized higher version to
  an authorized lower version
- complete sampling tool loops with `tools`, the three `toolChoice` modes,
  merged result/use metadata, explicit malformed-use errors, and an eight-round
  ceiling; advertise `sampling.tools` only when executable tools are configured
- bound both rate limiters with `max_clients: 10_000` by default and return
  `:overloaded` when live client cardinality remains full; response limiting now
  rejects limits below the smallest valid serialized tool-result envelope
- whitelist OpenAPI parameter locations without atom creation, apply override
  and style/explode rules, encode paths correctly, send scalar and array JSON
  bodies directly, and decode only JSON or `+json` responses
- reject fragment-bearing resource templates, external or cyclic filesystem
  symlinks, and skill files outside canonical roots; reloadable skill providers
  now reuse a runtime-owned metadata cache and hash only changed files
- deduplicate injected tools by component identity and use indexed exact
  Registry and atomic exact-or-template component lookups

### Bidirectional sessions and optional MCP facilities

- extend the session coordinator to own lifecycle, both request-id namespaces,
  active work, callback requests, output sinks, queued messages, progress
  tokens, logging thresholds, roots, peer tasks, URL elicitation, and SSE replay
- run inbound HTTP and stdio work under the runtime `Task.Supervisor`; support
  bidirectional cancellation and keep detached non-cancelled work supervised
  after an HTTP client disconnects
- make stdio concurrently read client responses and notifications while one
  serialized writer owns stdout; all diagnostics remain on stderr
- add `FastestMCP.Root`, `Context.list_roots/2`, cached roots, canonical
  `file://` validation, and roots-list-change refresh
- add standard form and URL elicitation, identity-bound completion through
  `FastestMCP.complete_elicitation/3`, `-32042` descriptors, HTTPS host
  allowlists through `url_elicitation_allowed_hosts:`, and completion
  notifications to the originating session only
- normalize the specification's backwards-compatible client capability
  `elicitation: {}` to effective `elicitation.form` support; URL mode still
  requires explicit `elicitation.url`
- add `FastestMCP.PeerTask` for task-augmented sampling and elicitation, with
  fetch, wait, result, cancel, and status-change helpers scoped to the exact
  originating server session, plus `Context.list_peer_tasks/2` for negotiated
  requester task listing
- add outbound ping, full sampling result validation and tool rounds, incoming
  progress callbacks, RFC 5424 logging thresholds, and bounded event rates
- add bounded logical SSE streams and same-stream `Last-Event-ID` replay; replay
  state is session-local and cleared on termination or runtime restart

### New default limits

- retain a 60-second request timeout and bound each session to 100,000 used
  request ids per direction, 128 pending callbacks, 128 active requests, 128
  peer tasks, 128 peer-task status callbacks, 1,024 queued peer messages, and
  16 MiB of queued message data
- bound each runtime to 10,000 pending callbacks, 10,000 active requests, and
  64 MiB of SSE replay data
- retain at most 256 replay events and 4 MiB per logical stream for five
  minutes; URL elicitation records expire after 15 minutes
- rate-limit outbound progress to 20 updates per second per token and inbound
  progress/logs to 100 updates per second per session
- cap JSON Schema sources at 1 MiB and nesting at 128 levels/256 references,
  with five-second compilation and one-second validation deadlines; cap opaque
  cursors at 4 KiB

### 0.1.x migration checklist

- remove `stateless_http:`, `stateless:`, `strict_input_validation:`,
  `dereference_schemas:`, initial client `session_id:`, `allowed_hosts: :any`,
  legacy REST-shaped MCP routes, batch requests, and remote `tasks/sendInput`
- use `state_scope: :request` when handler state must reset, while preserving
  the server-issued session id and initialize/initialized lifecycle
- send one JSON-RPC object per POST or stdio line; require object params and
  results, use only string/integer ids, and do not reuse ids within a session
- change tool input/output schemas to object-root JSON Schema and return
  schema-valid object `structuredContent`; values are no longer coerced
- move standard tool execution metadata to `execution.taskSupport`, keep only
  FastestMCP extensions under `_meta.fastestmcp`, and use direct standard fields
  on resource links and content blocks
- update sampling handlers to return complete `CreateMessageResult` objects
  with `role`, `content`, and `model`; form elicitation accepted content must be
  an object conforming to the requested schema
- continue list operations using the opaque `cursor` only; wire `pageSize` no
  longer controls the server-owned page size
- update custom task backends to the fallible fetch/expiry contracts described
  above and treat callback/progress/log delivery helpers as fallible operations
- configure concrete `allowed_hosts` for public mounts and, when RFC 9728
  discovery is needed, an exact `protected_resource:` plus an application-owned
  authenticator

## 0.1.2 - 2026-05-27

- refocus auth around application-owned authenticators, keeping the normalized
  `FastestMCP.Auth` contract, `FastestMCP.Auth.Result`,
  `FastestMCP.Auth.StaticToken`, and component authorization
- add function-based auth and `FastestMCP.Auth.from_assign/2` for Plug/Phoenix
  integrations
- add HTTP `auth_assigns:` support so selected `conn.assigns` can feed auth
  input without exposing assigns through handler request metadata
- remove bundled OAuth, JWT/JWKS, introspection, CIMD, and vendor auth provider
  modules, and remove the `:assent` and `:jose` dependencies
- remove the `:jason` dependency and use Elixir's native `JSON` module
- keep default HTTP auth failures on plain bearer challenges and remove built-in
  OAuth metadata/authorization/token route handling from core
- improve OpenAPI-backed tools with JSON media-type variants, form and
  multipart request bodies, cookie parameters, server variable defaults, and
  circular schema reference protection
- add multipart request support to `FastestMCP.HTTP.request/3`
- improve resource-template matching for hyphenated parameters, blank query
  values, collision rejection, and path-capture precedence
- add server `experimental_capabilities:` metadata for initialize responses
- improve mounted runtime behavior with self-mount rejection, recursive mounted
  lifespans, child-first cleanup, and stream shutdown before cleanup
- update tracing and error logging with MCP/GenAI span attributes, stable
  resource span names, `error.type`, nil-attribute filtering, arity-2 loggers,
  and per-error log levels
- document Phoenix-oriented auth, OpenAPI request serialization,
  resource-template matching, mounted lifespans, experimental capabilities,
  telemetry attributes, and error logging behavior
- add task wait behavior for input-required states, auth-scoped task ownership,
  and elicitation response metadata
- improve handler result normalization for safe finite enumerable values
- add regression coverage for auth contracts, Phoenix assign auth, task
  ownership, scalar elicitation, mounted wildcard resources, and tool/resource
  return normalization
- document auth assign bridging, task wait behavior, elicitation response
  metadata, and finite enumerable normalization

## 0.1.1 - 2026-04-17

- update broken project links in package metadata
- update the Hex package description to emphasize the BEAM-native MCP runtime,
  client, auth, and transport surfaces
