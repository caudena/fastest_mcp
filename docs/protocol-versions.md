# Protocol Versions

FastestMCP supports MCP `2026-07-28` and `2025-11-25` over streamable HTTP
and stdio. `2026-07-28` is preferred.

```elixir
FastestMCP.supported_protocol_versions()
# => ["2026-07-28", "2025-11-25"]

FastestMCP.current_protocol_version()
# => "2026-07-28"
```

The two revisions are separate wire profiles, not one payload with a renamed
version field:

| Concern | `2026-07-28` | `2025-11-25` |
| --- | --- | --- |
| Profile | modern | legacy |
| Startup | `server/discover` | `initialize`, then `notifications/initialized` |
| State | request-stateless protocol metadata | server-issued session |
| Version location | request `_meta` | initialize result and HTTP header |
| Capabilities | sent on each request; extensions are first-class | negotiated during initialize |
| Tasks | `io.modelcontextprotocol/tasks` extension v2 | experimental core Tasks v1 |

Use `FastestMCP.Protocol.profile/1` when application code genuinely needs to
branch on that profile. Do not infer the profile by date comparison.

## Client Preference

The connected client accepts exactly:

```elixir
protocol_version: :auto | "2026-07-28" | "2025-11-25"
```

The default is `:auto`. It probes `2026-07-28` with `server/discover`. On HTTP,
it falls back only when the status/body is credible legacy evidence, such as a
legacy method-not-found or an empty, unrecognized compatibility response;
authentication failures, rate limits, server failures, TLS errors, and network
errors do not silently downgrade. The stdio binding has a deliberately broader
compatibility rule: any response error not recognized as modern, or a probe
timeout, selects the legacy handshake on the same live child process. A
recognized modern error never triggers legacy initialization on either
transport.

Select an exact version for compatibility tests or a deployment migration:

```elixir
client =
  FastestMCP.Client.connect!(endpoint,
    protocol_version: "2025-11-25",
    client_info: %{"name" => "migration-check", "version" => "1.0.0"}
  )
```

`auto_initialize: false` disables automatic negotiation. With an exact legacy
selection, call `FastestMCP.Client.initialize/3`; with an exact modern
selection, call `FastestMCP.Client.discover/2`. If it is combined with
`protocol_version: :auto`, the application owns the probe and evidence-based
fallback decision.
Calling `initialize/3` directly remains the backwards-compatible way to select
the legacy handshake; it never pretends a modern connection has a session.

## One Server, Both Revisions

A running FastestMCP server accepts both revisions at the same endpoint and in
the same process. Version state belongs to the request or legacy session, not
to a global server switch. This permits old and new clients to overlap during
a rolling migration.

Do not translate one era into the other in a reverse proxy. In particular,
session headers, modern request metadata, Tasks fields, and method sets have
different semantics.

## Verification

CI exercises both protocol revisions with native tests and the official
`@modelcontextprotocol/conformance@0.2.0-alpha.11` runner.

The MCP revisions are released protocol specifications. The `alpha` label is
the maturity of the verification runner, not of MCP `2026-07-28`. CI runs each
runner requirement set separately and runs supported extension scenarios
explicitly because extension results are not part of the runner's core score.

See [Extensions](extensions.md), [Transports](transports.md), and
[Compatibility and Scope](compatibility-and-scope.md).
