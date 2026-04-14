# Why FastestMCP

FastestMCP aims for replacement-grade MCP server compatibility without turning
Elixir code into a Python-shaped runtime.

## Design Rules

- compatibility is the default
- divergence is allowed when Python's contract would fight OTP, explicit
  failure semantics, or normal Elixir application structure
- public Elixir APIs stay idiomatic even when the underlying MCP contract is
  Python-derived
- runtime ownership stays inside supervised Elixir processes

## What Changed from FastMCP

| Topic | FastMCP shape | FastestMCP shape |
| --- | --- | --- |
| Server startup | constructor and app oriented | `use FastestMCP.ServerModule` with generated `child_spec/1`, `start_link/1`, and `base_server/1` |
| Runtime model | framework process oriented | OTP-first with per-server runtime trees, supervised workers, and crash isolation |
| Context access | signature rewriting and injected helpers | explicit `%FastestMCP.Context{}` passed to handlers |
| HTTP integration | Starlette and ASGI first | Plug-first via `FastestMCP.http_app/2` and transport child specs |
| Client shape | convenience wrappers | connected `FastestMCP.Client` GenServer with negotiated session ownership |
| Dynamic components | app and provider management | internal `FastestMCP.ComponentManager` GenServer provider |
| Streaming | deprecated SSE history | streamable HTTP only; no standalone SSE transport |

## The Core Decisions

### Module-owned servers

Application-owned servers should look like application-owned Elixir code. A
module gives you a stable server identity, supervised startup, and config
resolution without inventing a second app container inside the app you already
have.

### Explicit context

FastestMCP does not rewrite handler signatures. Request state, session state,
principal data, auth details, and task metadata all live on
`FastestMCP.Context`, which makes lifetimes and failure modes visible.

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
the runtime feel native to Elixir. When the Python surface and OTP agree,
FastestMCP follows it. When they disagree, FastestMCP keeps the protocol and
changes the seam.
