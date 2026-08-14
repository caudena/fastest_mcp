# Why FastestMCP

FastestMCP aims for MCP server compatibility while keeping runtime ownership,
failure handling, and integration native to Elixir and OTP.

## Design Rules

- compatibility is the default
- divergence is allowed when a convention would fight OTP, explicit
  failure semantics, or normal Elixir application structure
- public Elixir APIs stay idiomatic while preserving the underlying MCP contract
- runtime ownership stays inside supervised Elixir processes

## Runtime Choices

| Topic | FastestMCP shape |
| --- | --- |
| Server startup | `use FastestMCP.ServerModule` with generated `child_spec/1`, `start_link/1`, and `base_server/1` |
| Runtime model | OTP-first with per-server runtime trees, supervised workers, and crash isolation |
| Context access | explicit `%FastestMCP.Context{}` passed to handlers |
| HTTP integration | Plug-first via `FastestMCP.http_app/2` and transport child specs |
| Protocol boundary | MCP `2026-07-28` and `2025-11-25` over strict JSON-RPC 2.0 at one configured `/mcp` endpoint |
| Client shape | connected `FastestMCP.Client` GenServer with latest-first negotiation and legacy session ownership |
| Dynamic components | internal `FastestMCP.ComponentManager` GenServer provider |
| Streaming | profile-aware streamable HTTP plus bidirectional stdio; bounded legacy-session replay and no standalone SSE transport |

## The Core Decisions

### Module-owned servers

Application-owned servers should look like application-owned Elixir code. A
module gives you a stable server identity, supervised startup, and config
resolution without inventing a second app container inside the app you already
have.

### Explicit context

Request state, session state, principal data, auth details, and task metadata
all live on `FastestMCP.Context`, which makes lifetimes and failure modes
visible.

### One operation pipeline

Tools, resources, templates, prompts, middleware, providers, auth, and
transforms all run through one shared execution pipeline. HTTP, stdio, and
in-process calls use the same behavior instead of growing separate seams that
drift over time.

### Runtime mutation stays in the runtime

Dynamic component changes go through `FastestMCP.ComponentManager`. There is no
separate REST management API pretending to be the source of truth while the OTP
system does the real work somewhere else.

## Where to Read Next

- [Onboarding](onboarding.md)
- [Compatibility and Scope](compatibility-and-scope.md)
- [Component Manager](component-manager.md)

## Why This Shape

The goal is not novelty. The goal is to preserve the MCP contract while making
the runtime feel native to Elixir. Protocol behavior stays stable while runtime
ownership follows OTP conventions.
