# Authentication and Authorization

FastestMCP can require credentials on every MCP request, and limit which tools,
resources, and prompts each caller sees and uses. Your application decides who
the caller is; FastestMCP enforces that decision on every request and gives the
identity to your handlers.

## Overview

Two pieces work together:

- **Authentication.** An *authenticator* receives the credentials of a request,
  usually the bearer token of its `Authorization` header, and returns the
  caller's identity or an error. You set it with `FastestMCP.add_auth/3`. Once a
  server has an authenticator, every HTTP request must pass it. A request that
  fails gets `401 Unauthorized`, or `403 Forbidden` when the identity lacks a
  required scope, with the `WWW-Authenticate` header that MCP clients expect.
- **Authorization.** Checks on individual tools, resources, and prompts, set
  with the `authorization:` option, decide which identities may use them.

Choose an authenticator by where your credentials come from:

| You have | Use |
| --- | --- |
| Local development, tests, a few fixed tokens | [`FastestMCP.Auth.StaticToken`](#static-tokens-for-development) |
| Tokens that your application issues | [a function](#authenticating-with-a-function) or [a module](#authenticator-modules) |
| A Phoenix plug that already identifies the caller | [`FastestMCP.Auth.from_assign/2`](#using-identities-from-phoenix) |
| Clients that sign users in with OAuth | [protected resource metadata](#oauth-protected-resource-metadata) and an authenticator for your tokens |

FastestMCP checks credentials; it doesn't issue tokens, show login pages, or
run an authorization server. In-process calls, such as `FastestMCP.call_tool/4`,
run the same authenticator with the credentials you pass as `auth_input:`, as
the examples below show, so your tests pass credentials too.

## Static tokens for development

`FastestMCP.Auth.StaticToken` accepts the tokens you list. It is the quickest
way to require a token during development and in tests:

```elixir
FastestMCP.server("notes-dev")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "dev-token" => %{client_id: "local-dev", scopes: ["notes:read", "notes:write"]}
  }
)
|> FastestMCP.add_tool("ping", fn _args, _ctx -> "pong" end)
|> FastestMCP.start_server!()

{:error, error} = FastestMCP.call_tool("notes-dev", "ping")
error.message
# => "missing credentials"

FastestMCP.call_tool!("notes-dev", "ping", %{},
  auth_input: %{"authorization" => "Bearer dev-token"}
)
# => "pong"
```

In process, pass the token as an `"authorization"` header value, as above, or
as `auth_input: %{"token" => "dev-token"}`. In a server module, call
`FastestMCP.add_auth/3` in `server/1`, right after `base_server/1`.

Each token maps to the identity it grants: a `client_id`, the `scopes` it
grants, and optionally a `principal` (by default `%{"client_id" => client_id}`),
`capabilities` (by default its scopes), `audiences`, an `auth` map, and an
`expires_at` time, as a `DateTime` or Unix seconds. The `required_scopes:`
option makes every request need those scopes.

Clients send the token as a bearer token. Over HTTP, a request without one gets
`401` with `WWW-Authenticate: Bearer`, and a token that the server doesn't know
gets `Bearer error="invalid_token", error_description="invalid credentials"`.
To connect with a token:

```elixir
client = FastestMCP.Client.connect!("http://localhost:4000/mcp", access_token: "dev-token")
```

In Claude Code, pass the header when you add the server:

```bash
claude mcp add --transport http notes http://localhost:4000/mcp \
  --header "Authorization: Bearer dev-token"
```

> #### Development and tests only {: .warning}
>
> `StaticToken` compares the tokens of your configuration and keeps the token
> in `ctx.auth`, so never return `ctx.auth` to clients. Read the tokens from
> your config, for example with `Application.fetch_env!(:my_app, :mcp_tokens)`,
> rather than writing them in your code, and use another authenticator for
> real users.

## Authenticating with a function

When your application issues its own tokens, verify them in a function. The
function receives the authentication input and the context, and returns
`{:ok, identity}` or `{:error, reason}`. This one accepts tokens signed with
`Phoenix.Token`:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_auth(fn input, _ctx ->
    with "Bearer " <> token <- input["authorization"],
         {:ok, user_id} <-
           Phoenix.Token.verify(MyAppWeb.Endpoint, "mcp", token, max_age: 30 * 86_400) do
      {:ok, %{principal: %{"sub" => to_string(user_id)}, scopes: ["notes:read", "notes:write"]}}
    else
      _missing_or_invalid -> {:error, :unauthorized}
    end
  end)

  # Then add your tools, resources, and prompts.
end
```

Your application issues the tokens, for example on a settings page, with
`Phoenix.Token.sign(MyAppWeb.Endpoint, "mcp", user.id)`.

Over HTTP, the input is a map with these keys:

| Key | Value |
| --- | --- |
| `"authorization"` | The `Authorization` header, or `nil` |
| `"headers"` | All request headers, with lowercase names |
| `"assigns"` | The assigns listed in the route's `auth_assigns:` option, if any |
| `"expected_resource"` and `"expected_scopes"` | With [protected resource metadata](#oauth-protected-resource-metadata), the resource and its required scopes |

For an in-process call, and a `FastestMCP.Client` connected in process, the
input is the `auth_input:` map you pass, as you pass it. Over stdio, it is the
`auth_input:` that `serve_stdio/1` was given, the same for every request of the
connection; see [Authentication over stdio](transports.md#authentication-over-stdio).

The identity is a map, or a `FastestMCP.Auth.Result`, with these keys, all
optional:

| Key | Meaning |
| --- | --- |
| `principal` | Who the caller is, in any shape you choose. Handlers read it as `ctx.principal`. |
| `scopes` | The scopes the caller holds, as your authenticator verified them. Authorization checks use them. |
| `audiences` | The resources the token was issued for, as verified. Required for [protected resources](#oauth-protected-resource-metadata). |
| `capabilities` | Application-defined permissions, for `FastestMCP.Authorization.require_capabilities/1`. |
| `auth` | Any other data for handlers, as `ctx.auth`. |

To reject a request, return `{:error, :unauthorized}` (`401`),
`{:error, :forbidden}` (`403`), `{:error, {code, message}}` with one of those
codes and your own message, or `{:error, %FastestMCP.Error{}}`. Over HTTP, an
error with the code `:rate_limited` gets `429`, and one with `:overloaded` or
`:timeout`, for a token service that is down or slow, gets `503` or `504`. A
function of three arguments also receives the options of
`FastestMCP.add_auth/3` as a map: given `salt: "mcp"`, its third argument is
`%{salt: "mcp"}`.

An authenticator that raises, throws, exits, or returns anything else, fails
the request with an `:internal_error`, which HTTP answers with `500`. The
client gets the message `authenticator MyApp.MCPAuthenticator failed`, or
`authenticator failed` for a function, and the exception's module, which is
`ErlangError` for a throw or an exit, but not its message, which can hold the
request's credentials; with `mask_error_details: true`, it gets
`authentication failed`. FastestMCP
doesn't log the exception: the error keeps it in its `cause`, the
[`[:fastest_mcp, :auth, :exception]` event](observability.md#the-events)
carries it with its stack trace, and the request's
[span](observability.md#opentelemetry-tracing) records it.

## Using identities from Phoenix

When a plug in your router already identifies the caller, FastestMCP can use
its result. The route's `auth_assigns:` option copies the listed assigns into
the authentication input, and `FastestMCP.Auth.from_assign/2` turns one of
them into the identity:

```elixir
FastestMCP.Auth.from_assign(:current_scope,
  principal: fn scope -> %{"sub" => to_string(scope.user.id)} end,
  scopes: fn _scope -> ["notes:read", "notes:write"] end
)
```

[Authenticate requests](phoenix.md#authenticate-requests) shows the plug and the
router for bearer tokens. A request whose assign is missing or `nil` gets `401`
with the message `missing or invalid credentials`; the message names no assign,
because clients receive it.

The options `principal`, `scopes`, `audiences`, `capabilities`, and `auth` take
a value, or a function of the assign, of the assign and the context, or of the
assign, the input, and the context. By default the principal is the assign
itself, `scopes`, `audiences`, and `capabilities` are empty, and `auth` is
`%{source: :assign, assign: :current_scope}`.

In tests and in-process calls, pass the assign in `auth_input:`, under
`"assigns"` and the assign's name, as the HTTP transport does. A client
connected in process takes the same map:

```elixir
FastestMCP.server("notes-phoenix")
|> FastestMCP.add_auth(
  FastestMCP.Auth.from_assign(:current_scope,
    principal: fn scope -> %{"sub" => to_string(scope.user.id)} end
  )
)
|> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)
|> FastestMCP.start_server!()

as_user = %{"assigns" => %{"current_scope" => %{user: %{id: 42}}}}

FastestMCP.call_tool!("notes-phoenix", "whoami", %{}, auth_input: as_user)
# => %{"sub" => "42"}

client = FastestMCP.Client.connect!({:in_process, "notes-phoenix"}, auth_input: as_user)
FastestMCP.Client.call_tool!(client, "whoami").structured_content
# => %{"sub" => "42"}
```

The assign keeps its shape, such as a `%MyApp.Accounts.Scope{}` struct from
`mix phx.gen.auth`, because the input stays in the BEAM.

## Authenticator modules

An authenticator module implements the `FastestMCP.Auth` behaviour. Use one to
reuse an authenticator, to configure it with options, or to test it on its own:

```elixir
# lib/my_app/mcp_authenticator.ex
defmodule MyApp.MCPAuthenticator do
  @behaviour FastestMCP.Auth

  @impl true
  def authenticate(%{"authorization" => "Bearer " <> token}, _ctx, opts) do
    case Phoenix.Token.verify(MyAppWeb.Endpoint, opts.salt, token, max_age: opts.max_age) do
      {:ok, user_id} ->
        {:ok,
         %FastestMCP.Auth.Result{
           principal: %{"sub" => to_string(user_id)},
           scopes: ["notes:read", "notes:write"]
         }}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  def authenticate(_input, _ctx, _opts), do: {:error, :unauthorized}
end
```

Add it in `server/1` with
`FastestMCP.add_auth(MyApp.MCPAuthenticator, salt: "mcp", max_age: 30 * 86_400)`.
`authenticate/3` receives the input, the context, and these options as a map.

## Authorizing components

Every tool, resource, resource template, and prompt takes an `authorization:`
option, with one check or a list of checks. `auth:` is another name for the
same option. A caller who fails a check doesn't see the component in lists, and
calling it fails with `:forbidden`:

```elixir
FastestMCP.server("notes-authz")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "reader-token" => %{client_id: "reader", scopes: ["notes:read"]},
    "writer-token" => %{client_id: "writer", scopes: ["notes:read", "notes:write"]}
  }
)
|> FastestMCP.add_tool("count_notes", fn _args, _ctx -> 2 end)
|> FastestMCP.add_tool("delete_notes", fn _args, _ctx -> "deleted" end,
  authorization: FastestMCP.Authorization.require_scopes("notes:write")
)
|> FastestMCP.start_server!()

reader = [auth_input: %{"authorization" => "Bearer reader-token"}]

FastestMCP.list_tools!("notes-authz", reader) |> Enum.map(& &1.name)
# => ["count_notes"]

{:error, error} = FastestMCP.call_tool("notes-authz", "delete_notes", %{}, reader)
error.code
# => :forbidden

FastestMCP.call_tool!("notes-authz", "delete_notes", %{},
  auth_input: %{"authorization" => "Bearer writer-token"}
)
# => "deleted"
```

Over HTTP, the denied call gets `403` with an `insufficient_scope` challenge
that names the missing scopes, so that an OAuth client can request a token
with them.

`FastestMCP.Authorization` provides these checks:

- `FastestMCP.Authorization.require_scopes/1` requires scopes that the
  authenticator verified. It never trusts scopes the client claims. Given a
  function of the `FastestMCP.Authorization.Context`, it computes the scopes
  for each request.
- `FastestMCP.Authorization.require_capabilities/1` requires capabilities from
  the identity.
- `FastestMCP.Authorization.restrict_tag/2` requires a scope, by default the
  tag itself, for the components that have a tag.
- A function of the `FastestMCP.Authorization.Context` allows access when it
  returns `true` or `:ok`. The context holds the identity and the component:

```elixir
FastestMCP.server("notes-admin")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "admin-token" => %{client_id: "admin", auth: %{role: :admin}},
    "user-token" => %{client_id: "user", auth: %{role: :user}}
  }
)
|> FastestMCP.add_tool("purge_notes", fn _args, _ctx -> "purged" end,
  authorization: fn authz -> authz.auth[:role] == :admin end
)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("notes-admin", auth_input: %{"authorization" => "Bearer user-token"})
# => []

FastestMCP.call_tool!("notes-admin", "purge_notes", %{},
  auth_input: %{"authorization" => "Bearer admin-token"}
)
# => "purged"
```

Checks also run when a client lists components, and then there are no
arguments. A check that depends on the arguments therefore hides the component
from every list. To decide who may change a particular record, check in the
handler instead, and raise `FastestMCP.Error` with the code `:forbidden`.

To add a check to every component of a server, use
`FastestMCP.Authorization.transform/2` as a server transform:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_transform(
    FastestMCP.Authorization.transform(FastestMCP.Authorization.require_scopes("notes:read"))
  )

  # Then add your tools, resources, and prompts.
end
```

Checks fail closed: anything other than `true` or `:ok`, including an
exception, denies access.

## What handlers see

The handler's context carries the identity:

```elixir
FastestMCP.server("notes-whoami")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"dev-token" => %{client_id: "local-dev", scopes: ["notes:read"]}}
)
|> FastestMCP.add_tool("whoami", fn _args, ctx ->
  %{
    principal: ctx.principal,
    scopes: ctx.verified_scopes,
    client_id: FastestMCP.Context.client_id(ctx)
  }
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-whoami", "whoami", %{},
  auth_input: %{"authorization" => "Bearer dev-token"}
)
# => %{client_id: "local-dev", scopes: ["notes:read"], principal: %{"client_id" => "local-dev"}}
```

| Field | Value |
| --- | --- |
| `ctx.principal` | The identity's `principal`; `nil` without authentication |
| `ctx.authenticated` | `true` when an authenticator accepted the request |
| `ctx.verified_scopes` | The identity's `scopes` |
| `ctx.verified_audiences` | The identity's `audiences` |
| `ctx.capabilities` | The identity's `capabilities` |
| `ctx.auth` | The identity's `auth` map |

The authenticator returns `scopes` and `audiences`; the context names them
`verified_scopes` and `verified_audiences`. `FastestMCP.Context.client_id/1`
returns the `client_id` of `ctx.auth`, or else the `client_id` or `sub` of the
principal, and `nil` without either, on every transport and protocol version.
It never returns the name a client gives for itself, which nobody verified;
that name is in the [request metadata](context.md#request-metadata).

## OAuth protected resource metadata

MCP clients such as Claude can sign users in with OAuth. The client calls your
server without a token and gets `401`, with a `WWW-Authenticate` header that
points to your server's protected resource metadata (RFC 9728). The metadata
names the authorization server that issues tokens for your server. The client
signs the user in there, receives an access token, and calls your server again
with it. FastestMCP publishes the metadata and the challenges; your
authorization server issues the tokens, and your authenticator verifies them.

Describe the resource with the `protected_resource` server option. Its values
differ between environments, so set them in your config through `otp_app:`:

```elixir
# In lib/my_app/mcp_server.ex
use FastestMCP.ServerModule, otp_app: :my_app
```

```elixir
# In config/dev.exs
config :my_app, MyApp.MCPServer,
  protected_resource: [
    resource: "http://localhost:4000/mcp",
    authorization_servers: ["https://auth.example.com"],
    scopes_supported: ["notes:read", "notes:write"],
    required_scopes: ["notes:read"]
  ]
```

- `resource` is the exact URL of your MCP endpoint. It must use `https`, except
  on `localhost`, so in production set it in `config/runtime.exs`, as in
  `resource: "https://#{host}/mcp"`, with the other keys.
- `authorization_servers` lists the authorization servers that issue tokens for
  it, as `https` URLs.
- `required_scopes` are the scopes every request needs. It defaults to all of
  `scopes_supported`, so set it.

The metadata needs a route of its own in your router; see
[OAuth](phoenix.md#oauth) in the Phoenix guide. A request without a token then
gets a challenge like this one:

```text
WWW-Authenticate: Bearer resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource/mcp", scope="notes:read"
```

A token that your authenticator rejects gets the same challenge with
`error="invalid_token"` and the authenticator's message as
`error_description`.

Your authenticator verifies the access token as your authorization server
defines it, for example by checking a JWT's signature, issuer, and expiry, or by
calling the server's token introspection endpoint. It returns the audiences and
scopes it verified:

```elixir
{:ok,
 %FastestMCP.Auth.Result{
   principal: %{"sub" => "user-123"},
   audiences: ["https://notes.example.com/mcp"],
   scopes: ["notes:read", "notes:write"]
 }}
```

FastestMCP then rejects the request with `401` unless `audiences` contains the
configured resource, and with `403` unless `scopes` contains every required
scope. The input of the authenticator carries the resource and the required
scopes as `"expected_resource"` and `"expected_scopes"`.

To try the flow before you connect an authorization server, give
`FastestMCP.Auth.StaticToken` a token whose `audiences` contain the resource:

```elixir
FastestMCP.server("notes-oauth",
  protected_resource: [
    resource: "http://localhost:4000/mcp",
    authorization_servers: ["https://auth.example.com"],
    scopes_supported: ["notes:read", "notes:write"],
    required_scopes: ["notes:read"]
  ]
)
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "dev-token" => %{
      client_id: "local-dev",
      scopes: ["notes:read"],
      audiences: ["http://localhost:4000/mcp"]
    }
  }
)
|> FastestMCP.add_tool("ping", fn _args, _ctx -> "pong" end)
|> FastestMCP.start_server!()
```

## Details

### Identity fields and their older names

An authenticator may return its identity as a `FastestMCP.Auth.Result` or as a
map with atom or string keys. The keys `verified_scopes` and
`verified_audiences` are accepted as older names of `scopes` and `audiences`.
An identity that gives both names with different values fails authentication.

### Which requests are authenticated

Over HTTP, FastestMCP authenticates every request, including notifications and
the client's answers to server requests. With protocol version `2025-11-25`,
it also authenticates the `GET` and `DELETE` requests of a session, binds the
session to the identity of its first request, and rejects requests from
another identity with `403`. With `2026-07-28`, every request stands alone.
In process and over stdio, `ping` skips authentication, and the handshake,
`initialize` or `server/discover`, authenticates only the credentials it
carries: a client negotiates its protocol version with or without credentials,
the server's capabilities are those of the caller that the credentials name,
and the requests after the handshake are authenticated. Over stdio, a
request's `_meta.fastestmcp.auth` map, which a `FastestMCP.Client` sends with
`legacy_stdio_auth_metadata: true`, adds keys to the `auth_input:` of
`serve_stdio/1`, without replacing any. A request with an `access_token`
query parameter is rejected
with `400` before the authenticator runs: tokens belong in the `Authorization`
header.

The challenge of a `401` names an error only when the request carried an
`Authorization` header: a request without credentials gets `Bearer`, or with
protected resource metadata `Bearer resource_metadata="...", scope="..."`, as
RFC 6750 asks. Every authentication emits the
[authentication telemetry events](observability.md#the-events), over HTTP too.

### Denied requests

List requests leave out the components a caller may not use, without an error.
A direct call that scope checks deny gets `403` with an `insufficient_scope`
challenge that lists every missing scope; `FastestMCP.Authorization.restrict_tag/2`
makes a scope check too. Any other `403` is plain, without a challenge, since
no other token would help: when a function or capability check also denies the
call, when a function that computes scopes fails, which names no scopes so that
clients can't discover your policy, and when your authenticator itself returns
`{:error, :forbidden}`, for example for a valid token of someone without an
account.

When several versions of a component share a name, a call that names no
version uses the newest version the caller may use. A call that asks for a
version the caller may not use is rejected.

### Protected resource rules

The resource must be an absolute `http` or `https` URL without a query or
fragment, and `http` only on `localhost` and loopback addresses. Every
authorization server must use `https`, and the list can't be empty. The
required scopes must be among `scopes_supported` when you give it. A server with
protected resource metadata but no authenticator rejects every request.

Over HTTP, the URL of each request, with the path a router forwards to it, must
be the resource; any other URL gets `403` with
`request URI does not match the configured protected resource`, and no scope
challenge. Behind a proxy, set `base_url:`; see [OAuth](phoenix.md#oauth).

### Configuring auth as a server option

`FastestMCP.server/2`, and so `use FastestMCP.ServerModule` and its config,
also accept the authenticator as the `auth:` option, in any form that
`FastestMCP.Auth.new/2` accepts, such as
`auth: {MyApp.MCPAuthenticator, salt: "mcp", max_age: 30 * 86_400}`.

## See also

- [Phoenix](phoenix.md): the router, pipelines, and testing through the
  endpoint
- [Client Authentication](client-auth.md): connecting to servers that require
  credentials
- [Context](context.md): the handler context
- `FastestMCP.Auth`, `FastestMCP.Auth.StaticToken`, `FastestMCP.Authorization`,
  and `FastestMCP.Auth.ProtectedResource`
