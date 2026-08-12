# Compatibility and Scope

FastestMCP targets MCP server behavior plus the Elixir-native companion
surfaces required to use that server plane cleanly from Elixir code.

Compatibility is the default for protocol-visible behavior, but divergence is
allowed when a convention would fight OTP, explicit failure semantics, or normal
Elixir application structure.

## Supported Protocol

FastestMCP 0.2 targets MCP `2025-11-25` across streamable HTTP and stdio. The
shared schema, JSON-RPC, Session, transport, and operation boundaries are
covered by native tests, raw-peer transport tests, and separate direct and
narrowly shimmed conformance-runner lanes. Version 0.2.0 remains unreleased.

## Compatibility Rules

- compatibility is the default
- divergence must be intentional, documented, and tested
- deprecated surfaces are not revived without a current Elixir use case
- public Elixir APIs should stay idiomatic while preserving the underlying MCP
  contract
- optional capabilities are derived from implemented handlers and runtime
  configuration; caller-supplied maps cannot advertise unsupported behavior
- non-standard wire metadata is never an authentication channel by default

## Included Surface

The active compatibility target includes:

- MCP `2025-11-25` as the sole protocol version
- server declaration and lifecycle
- tools, resources, resource templates, and prompts
- standard prompt/resource wire completion plus Elixir-native tool and
  resource-template completion helpers
- middleware, providers, auth, and transport-independent execution
- explicit request, session, and task context handling
- request-context snapshots and narrow current-context helpers for nested code
- streamable HTTP and stdio server behavior
- strict JSON-RPC 2.0 with one message per HTTP POST or stdio line
- per-server runtime isolation, overload handling, and task supervision
- connected client support for streamable HTTP and stdio
- asynchronous connected-client requests with explicit cancellation and
  caller-lifetime cleanup
- connected client completions and session-scoped resource subscriptions
- client-side roots, logging-level control, sampling, form/URL elicitation,
  completion tracking, log, and progress callbacks
- server-side sampling and interaction helpers
- server-originated roots, ping, cancellation, progress, logging, form and URL
  elicitation, and requester-side peer tasks
- identity-bound URL-elicitation completion
- RFC 9728 Protected Resource Metadata for configured HTTP resource servers
- an OAuth 2.1 HTTP client boundary with RFC 8414/OIDC discovery, PKCE S256,
  RFC 8707 resource indicators, explicit registration, refresh rotation, and
  bounded scope step-up
- bounded same-session, same-stream SSE event replay and client resumption
- RFC 6570 level 1-4 resource-template parsing, expansion, and reverse routing
- Draft 2020-12 and Draft 7 JSON Schema through one non-coercing compile-once
  boundary
- runtime component mutation through `FastestMCP.ComponentManager`
- explicit tool, prompt, and resource helper types for richer payload shaping
- session-state backend configuration through `FastestMCP.SessionStateStore`
- task-state backend configuration through `FastestMCP.TaskBackend`
- unified `on_duplicate:` semantics for local server and runtime component registration
- centralized protocol version and capability helpers
- explicit experimental capability advertisement through server metadata
- native regression coverage plus live HTTP and conformance lanes

## Explicitly Deferred

The following are intentionally outside the current milestone:

- CLI tooling
- cluster-aware runtime behavior
- publishing automation after the first manual Hex release is proven
- custom app or UI layer
- deprecated compatibility behaviors

## Intentional Elixir-native Divergences

- No standalone SSE transport. The supported HTTP transport is streamable HTTP
  only.
- No legacy method-specific HTTP routes or JSON-RPC batches. MCP traffic uses
  the single configured endpoint, `/mcp` by default.
- Remote task augmentation is limited to standard `tools/call`. Local Elixir
  prompt/resource tasks remain runtime conveniences rather than wire
  extensions, and there is no `tasks/sendInput` MCP method.
- No signature rewriting or annotation-based dependency injection. Elixir keeps
  explicit `%FastestMCP.Context{}` and
  `FastestMCP.add_dependency/3`.
- Convenience exists only as narrow helpers such as `Context.current!/0`,
  `Context.request_context/1`, and `Context.client_id/1`. Explicit handler
  `ctx` remains the primary style.
- HTTP integration stays Plug-first.
- No external component management REST API. Runtime mutation lives inside the
  supervised runtime through `FastestMCP.ComponentManager`.
- Client ergonomics are session-first and GenServer-based.
- FastestMCP does not implement an authorization server. RFC 9728
  protected-resource discovery and challenges plus the connected-client OAuth
  flow are available, while token issuance, signing, introspection,
  authorization UI, and authorization-server operation stay host-owned or
  external.

## Reference Boundary

The compatibility target covers both the advertised server and connected-client
surfaces. Server behavior is exercised directly against the production Plug;
client behavior is exercised by a test-only official-runner adapter that uses
only public `FastestMCP.Client` APIs.

## Current State

Current status:

- the 0.2 implementation has one shared schema/JSON-RPC boundary and one
  bidirectional Session coordinator for HTTP and stdio
- connected client support exists for streamable HTTP and stdio
- standard completion, sampling tool rounds, form and URL elicitation, roots,
  requester tasks, cancellation, progress, logging, ping, OAuth, SSE replay,
  and RFC 6570 templates have focused native and raw-peer transport coverage
- runtime component mutation is implemented through `FastestMCP.ComponentManager`
- explicit tool, prompt, and resource helper modules are part of the curated public API
- session-state storage is configurable; broader runtime storage is still local
- standalone SSE remains an intentional non-goal; GET SSE is part of the
  Streamable HTTP endpoint
- zero-session HTTP is removed; `state_scope: :request` resets handler state
  while retaining a normal negotiated MCP session

Treat advertised capabilities and executable transport tests—not merely the
presence of a helper or a green shimmed runner—as the support boundary.

## Why This Shape

This page owns the explicit boundary. The rationale page explains the design
philosophy, but this page is the contract for what FastestMCP supports, what it
deliberately does not support, and what remains outside the current release.
