# Changelog

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
