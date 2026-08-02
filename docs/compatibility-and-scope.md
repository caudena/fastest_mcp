# Compatibility and Scope

FastestMCP targets MCP server behavior plus the Elixir-native companion
surfaces required to use that server plane cleanly from Elixir code.

Compatibility is the default for protocol-visible behavior, but divergence is
allowed when a convention would fight OTP, explicit failure semantics, or normal
Elixir application structure.

## Compatibility Rules

- compatibility is the default
- divergence must be intentional, documented, and tested
- deprecated surfaces are not revived without a current Elixir use case
- public Elixir APIs should stay idiomatic while preserving the underlying MCP
  contract
- FastestMCP-specific wire extensions, such as `_meta.fastestmcp`, are part of
  the public transport contract and should stay consistent across transports

## Included Surface

The active compatibility target includes:

- MCP `2025-11-25` as the sole protocol version
- server declaration and lifecycle
- tools, resources, resource templates, and prompts
- tool, prompt, and resource-template completions
- middleware, providers, auth, and transport-independent execution
- explicit request, session, and task context handling
- request-context snapshots and narrow current-context helpers for nested code
- streamable HTTP and stdio server behavior
- strict JSON-RPC 2.0 with one message per HTTP POST or stdio line
- per-server runtime isolation, overload handling, and task supervision
- connected client support for streamable HTTP and stdio
- connected client completions and session-scoped resource subscriptions
- client-side sampling, elicitation, log, and progress callbacks
- server-side sampling and interaction helpers
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

## Reference Boundary

The compatibility target remains server-focused. The newer Elixir-native
companion surfaces, such as the connected client and component manager, are
covered by native FastestMCP tests.

## Current State

Current status:

- replacement-grade server plane is implemented for the active scope
- connected client support exists for streamable HTTP and stdio
- completion exists for tools, prompts, and resource templates
- sampling and elicitation helpers are implemented for server-side usage
- runtime component mutation is implemented through `FastestMCP.ComponentManager`
- explicit tool, prompt, and resource helper modules are part of the curated public API
- session-state storage is configurable; broader runtime storage is still local
- standalone SSE remains an intentional non-goal
- stateless HTTP is request-scoped and intentionally omits session, task, and
  subscription behavior

Anything not listed above should be treated as deferred or intentionally out of
scope until documented otherwise.

## Why This Shape

This page owns the explicit boundary. The rationale page explains the design
philosophy, but this page is the contract for what FastestMCP supports, what it
deliberately does not support, and what remains outside the current release.
