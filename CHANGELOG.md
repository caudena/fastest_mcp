# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - 2026-08-02

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
- pin the official server conformance runner to
  `@modelcontextprotocol/conformance@0.1.16` and run it without expected-failure
  allowances

### Sessions and request lifecycle

- make stateful streamable HTTP sessions server-issued: `initialize` must not
  send `MCP-Session-Id`; the successful response supplies it, and subsequent
  requests must echo it
- enforce `initialize` followed by `notifications/initialized` before other
  requests, both for stateful HTTP sessions and each stdio connection
- require `MCP-Protocol-Version: 2025-11-25` on stateful HTTP requests after
  initialization, and reject unknown or terminated sessions
- make stateless HTTP POST-only and request-scoped: it creates no session,
  advertises no task or subscription capability, and rejects task augmentation,
  resource subscriptions, GET, and DELETE
- add explicit context `state_scope`, negotiated protocol, and client
  capability fields; `Context.session_id` is now `nil` for stateless requests
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
- remove `allowed_hosts: :any`; use a non-empty concrete host list, or set
  `unsafe_allow_any_host: true` as an explicit opt-out
- require non-loopback listeners to configure concrete allowed hosts unless the
  unsafe opt-out is explicit
- expose `FastestMCP.Auth.Result`, `FastestMCP.Auth.StaticToken`,
  `FastestMCP.TaskBackend`, and `FastestMCP.TaskBackend.Memory` in HexDocs
- source the ExDoc module filter and module groups from one shared public-module
  catalog so published docs cannot drift from the navigation groups
- add provider candidate callbacks for deterministic all-version resolution,
  including lower-version fallback after visibility or policy filtering
- centralize duplicate component policy and preserve `:warn` as
  warn-and-replace across server, local-provider, and component-manager
  registration
- correct middleware examples to use `max_requests_per_second:`,
  `max_requests:`/`window_minutes:`, and `max_size:`

### Schema, sampling, providers, and middleware

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
