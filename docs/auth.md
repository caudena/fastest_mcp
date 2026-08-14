# Auth

Auth is application-owned. FastestMCP keeps a small runtime contract that turns
credentials or framework state into normalized request context:

- `ctx.principal`
- `ctx.auth`
- `ctx.authenticated`
- `ctx.capabilities`
- `ctx.verified_scopes`
- `ctx.verified_audiences`
- `Context.client_id/1`

Your application verifies sessions, tokens, cookies, or upstream identity using
its normal stack. FastestMCP only needs the normalized result.

## Function Auth

Pass a function directly when auth is specific to the host application:

```elixir
FastestMCP.server("app")
|> FastestMCP.add_auth(fn input, _ctx ->
  case MyApp.Auth.verify_mcp_request(input) do
    {:ok, user} ->
      {:ok,
       %{
         principal: %{"sub" => to_string(user.id)},
         auth: %{source: :app, user_id: user.id},
         scopes: MyApp.MCPScopes.for_user(user),
         audiences: ["https://mcp.example.com/mcp"]
       }}

    :error ->
      {:error, :unauthorized}
  end
end)
```

The function may have arity 2 or 3. Arity 3 receives the configured auth
options as the third argument.

## Module Auth

Use the behaviour when you want a reusable authenticator module:

```elixir
defmodule MyApp.MCPAuth do
  @behaviour FastestMCP.Auth

  @impl true
  def authenticate(input, _ctx, opts) do
    with {:ok, user} <- MyApp.Auth.verify(input, opts) do
      {:ok,
       %FastestMCP.Auth.Result{
         principal: %{"sub" => to_string(user.id)},
         auth: %{source: :app, user_id: user.id},
         scopes: MyApp.MCPScopes.for_user(user),
         audiences: ["https://mcp.example.com/mcp"]
       }}
    end
  end
end

FastestMCP.server("app")
|> FastestMCP.add_auth(MyApp.MCPAuth, audience: "mcp")
```

Auth errors should return `{:error, :unauthorized}`,
`{:error, :forbidden}`, `{:error, {code, message}}`, or
`{:error, %FastestMCP.Error{}}`.

## Phoenix Assigns

When the HTTP transport runs behind Plug or Phoenix authentication, copy selected
`conn.assigns` into auth input with `auth_assigns:`. Assigns are available only
to the auth function or module under `"assigns"`; they are not added to normal
handler request metadata.

```elixir
pipeline :mcp do
  plug :fetch_session
  plug MyAppWeb.UserAuth, :fetch_current_user
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", FastestMCP.Transport.HTTPApp,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    auth_assigns: [:current_user]
end
```

`FastestMCP.Auth.from_assign/2` turns one assign into a normalized auth result:

```elixir
FastestMCP.server(MyApp.MCPServer)
|> FastestMCP.add_auth(
  FastestMCP.Auth.from_assign(:current_user,
    principal: fn user -> %{"sub" => to_string(user.id)} end,
    scopes: fn user -> MyApp.MCPScopes.for_user(user) end,
    audiences: fn _user -> ["https://mcp.example.com/mcp"] end,
    auth: fn user -> %{source: :phoenix, user_id: user.id} end
  )
)
```

`auth_assigns:` accepts:

- `false` or `nil` to copy no assigns
- `[:current_user, :account]` to copy specific assigns
- `:all` to copy every assign

The default is `false`.

## Static Token

`FastestMCP.Auth.StaticToken` is kept for local development, integration tests,
and hermetic tooling:

```elixir
FastestMCP.server("dev")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "dev-token" => %{
      client_id: "local-client",
      scopes: ["tools:call"],
      principal: %{"sub" => "local-client"}
    }
  },
  required_scopes: ["tools:call"]
)
|> FastestMCP.add_tool("whoami", fn _arguments, ctx ->
  %{principal: ctx.principal, auth: ctx.auth}
end)
```

Static tokens can be supplied as an HTTP bearer token, as `"authorization"` in
direct `auth_input`, or as `"token"` in direct `auth_input`.

## Component Authorization

Authentication identifies the caller. Component authorization decides which
tools, resources, prompts, and templates the caller may see or call.

```elixir
FastestMCP.server("app")
|> FastestMCP.add_tool("admin_report", &MyApp.Report.run/2,
  auth: FastestMCP.Authorization.require_scopes(["admin:reports"])
)
```

Authorization rules can also filter list results with tags:

```elixir
FastestMCP.Authorization.restrict_tag("internal")
```

`require_scopes/1` checks only scopes verified by the authenticator. It never
uses client capabilities or unverified token claims. A dynamic resolver receives
`%FastestMCP.Authorization.Context{}` and runs once per authorization decision:

```elixir
FastestMCP.Authorization.require_scopes(fn authz ->
  if authz.arguments["confidential"], do: ["reports:confidential"], else: ["reports:read"]
end)
```

The authorization context includes the authenticated state, verified scopes and
audiences, operation target and arguments, and canonical decoded resource-template
captures. Use `require_capabilities/1` when the application intentionally wants
a capability-based check instead:

```elixir
FastestMCP.Authorization.require_capabilities(["internal-tools"])
```

Authorization is fail closed. A custom function check authorizes only when it
returns `true` or `:ok`. `false`, `nil`, malformed return values, exceptions,
throws, exits, and error tuples all deny access. Custom checks are opaque: their
denial details are not exposed on the wire. When multiple versions share an
identity, an unauthorized higher version is skipped so an authorized lower
version can remain visible, while an explicit request for the unauthorized
version is rejected.

## HTTP Behavior

When a server configures auth, FastestMCP authenticates every applicable
inbound HTTP request, notification, client response, and control operation
before dispatch. A legacy initialize identity is bound to its session; a
different principal cannot reuse that session id. Modern requests are
stateless authentication boundaries. Component authorization still runs in
the operation pipeline after transport authentication.

List operations silently omit unauthorized components. Direct access with a
verified token that lacks one or more declared scopes returns HTTP 403 and an
`insufficient_scope` challenge containing the union of missing scopes. If any
custom, capability, or failed dynamic check also denies the operation, the
response remains a generic 403 and does not disclose scope requirements.

Without protected-resource configuration, HTTP auth failures use a plain
bearer challenge:

```text
WWW-Authenticate: Bearer error="invalid_token", error_description="missing credentials"
```

### RFC 9728 Protected Resource Metadata

Configure `protected_resource:` when standards-aware clients must discover the
authorization server and authoritative scopes for the MCP endpoint:

```elixir
server =
  FastestMCP.server("documents",
    auth: MyApp.MCPAuth,
    protected_resource: [
      resource: "https://mcp.example.com/mcp",
      authorization_servers: ["https://auth.example.com"],
      scopes_supported: ["documents:read", "documents:write"],
      required_scopes: ["documents:read"]
    ]
  )
```

The path-derived metadata document must be served on the same resource origin.
For a standalone FastestMCP listener the HTTP app serves it directly. A Phoenix
application that forwards only `/mcp` must separately mount
`FastestMCP.Transport.WellKnownHTTP` outside its authenticated pipeline, as
shown in [Phoenix Deployment](phoenix-deployment.md). For the example above the
public URL is:

```text
https://mcp.example.com/.well-known/oauth-protected-resource/mcp
```

Authentication failures include both discovery and authoritative scope:

```text
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="documents:read", error="invalid_token"
```

The configured `resource` must be the exact absolute MCP resource URI.
Non-loopback resources and every authorization-server URI must use HTTPS, and
the authorization-server list cannot be empty. Access tokens in query strings
are rejected before the authenticator runs. The authenticator receives
`"expected_resource"` and `"expected_scopes"` in its input and the same values
in request metadata.

For a protected resource, successful authentication must return verified
evidence, not merely untrusted token claims:

```elixir
{:ok,
 %FastestMCP.Auth.Result{
   principal: %{"sub" => subject},
   audiences: ["https://mcp.example.com/mcp"],
   scopes: ["documents:read"]
 }}
```

`audiences` identifies the resource audiences the host authenticator actually
verified, and `scopes` identifies the granted scopes it actually verified.
When protected-resource auth is enabled, FastestMCP fails closed unless the
configured resource is present in `audiences` and every required scope is
present in `scopes`. Those values survive the request-context handoff for
component authorization; a session id is never accepted as authentication.

The older `verified_audiences` and `verified_scopes` struct/map keys remain
accepted as compatibility aliases. New authenticators should use `audiences`
and `scopes`; conflicting values are rejected.

FastestMCP remains the protected resource server. Authorization-server token
issuance, signing, introspection, consent UI, and authorization-server
operation stay application-owned or external. Signature/opaque-token
verification is the authenticator's responsibility; FastestMCP enforces the
verified audience and scope evidence returned by that boundary. Configure
`FastestMCP.Auth.ProtectedResource` only together with an authenticator;
protected-resource HTTP fails closed when no authenticator exists.

## Connected-Client Extension Grants

The connected client also supports the draft OAuth Client Credentials and
stable Enterprise-Managed Authorization extensions. They stay under the
existing `oauth:` option as tagged `grant:` values. Client Credentials accepts
a host secret or an arity-one `private_key_jwt` assertion provider.
Enterprise-Managed Authorization accepts an arity-one host identity provider
and explicit pre-registration or Client ID Metadata Document registration.
Selecting either tagged grant is the explicit opt-in and automatically
declares its matching extension capability on every modern MCP request.

These grants change how a client obtains a bearer token. They do not add token,
login, IdP, or authorization routes to a FastestMCP server. Exact shapes and
maturity labels are documented in [Protocol Extensions](extensions.md).

The connected-client OAuth flow and its host-owned browser, signing,
enterprise identity, and token-store boundaries are documented in
[Client](client.md). The Phoenix resource-server deployment boundary is in
[Phoenix Deployment](phoenix-deployment.md).

## Why This Shape

Phoenix applications usually already own authentication, sessions, user loading,
authorization policy, and audit metadata. Keeping FastestMCP auth as a small
contract avoids a second identity stack while preserving consistent context for
handlers, middleware, tasks, transports, and component visibility.
