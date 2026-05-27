# Changelog

All notable changes to this project will be documented in this file.

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
