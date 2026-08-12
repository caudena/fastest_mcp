# Vendored MCP protocol schema

`mcp-2025-11-25.schema.json` is vendored without modification from the
official Model Context Protocol repository:

- revision: `2025-11-25`
- source commit: `38c84e9f93ad191d9eb26d92b945d17bd0efcaf3`
- source path: `schema/2025-11-25/schema.json`
- SHA-256: `1ffe4c5577974012f5fa02af14ea88df4b7146679df1abaaad497c8d9230ca8a`
- upstream license: MIT; see `LICENSE.upstream`

Update the file, checksum, and source commit together. Never regenerate it
from a moving branch.

`FastestMCP.Schema` verifies this checksum before compiling tagged protocol
definitions through JSV `0.21.2`. Focused tests exercise FastestMCP's dialect,
resolver, caching, and resource-limit contract; general JSON Schema conformance
is delegated to JSV. See `docs/schema-validation.md` for the supported boundary.

The generated artifact types `NumberSchema.minimum`, `maximum`, and `default`
as integers even though authoritative `schema.ts` at the same commit and the
tagged elicitation specification define them as numbers. The vendored bytes are
not edited: `FastestMCP.Schema` applies an explicitly versioned correction only
to its compiled protocol view, with tests for the source checksum and corrected
definitions.
