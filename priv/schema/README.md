# Bundled MCP protocol schemas

FastestMCP includes the official schemas for both supported core revisions:

- MCP `2026-07-28`; see `LICENSE.upstream-2026-07-28`
- MCP `2025-11-25`; see `LICENSE.upstream`

Extension schemas are included separately because extensions are versioned
independently from the core protocol:

- draft `io.modelcontextprotocol/tasks`; see `LICENSE.upstream-tasks`
- MCP Apps v1.0.0, `io.modelcontextprotocol/ui`; see
  `LICENSE.upstream-apps`

The package includes these schemas and their upstream license notices.
`FastestMCP.Schema` compiles the protocol definitions through JSV. Focused
tests exercise FastestMCP's dialect, resolver, caching, and resource-limit
contract; general JSON Schema conformance is delegated to JSV. See
`docs/schema-validation.md` for the supported boundary.

The published 2025-11-25 schema types `NumberSchema.minimum`, `maximum`, and
`default` as integers even though the corresponding TypeScript definitions and
elicitation specification define them as numbers. The bundled artifact is not
edited: `FastestMCP.Schema` applies an explicitly versioned correction only to
its compiled protocol view, with tests for the corrected definitions.
