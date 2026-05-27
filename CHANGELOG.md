# Changelog

All notable changes to this project will be documented in this file.

## 0.1.2 - 2026-05-27

- add OAuth redirect hardening for raw and decoded dot segments, stricter empty
  redirect allowlists, remembered consent cookies, synthetic public proxy
  clients, and refresh-token lifetime bounding
- add Azure token issuer overrides, Azure B2C provider factory support, and the
  OCI OAuth provider wrapper
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
- document OAuth consent and provider options, OpenAPI request serialization,
  resource-template matching, mounted lifespans, experimental capabilities,
  telemetry attributes, and error logging behavior
- add task wait behavior for input-required states, auth-scoped task ownership,
  OAuth protected-resource base URLs, and elicitation response metadata
- add Keycloak and WorkOS AuthKit resource-server auth providers
- improve handler result normalization for safe finite enumerable values
- add regression coverage for OAuth metadata/JWT audiences, AuthKit audience
  binding, task ownership, scalar elicitation, mounted wildcard resources, and
  tool/resource return normalization
- document the new auth providers, OAuth `resource_base_url`, task wait
  behavior, elicitation response metadata, and finite enumerable normalization

## 0.1.1 - 2026-04-17

- update broken project links in package metadata
- update the Hex package description to emphasize the BEAM-native MCP runtime,
  client, auth, and transport surfaces
