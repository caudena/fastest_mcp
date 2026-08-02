# Auth

Auth is application-owned. FastestMCP keeps a small runtime contract that turns
credentials or framework state into normalized request context:

- `ctx.principal`
- `ctx.auth`
- `ctx.capabilities`
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
         capabilities: MyApp.MCPScopes.for_user(user)
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
         capabilities: MyApp.MCPScopes.for_user(user)
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
    capabilities: fn user -> MyApp.MCPScopes.for_user(user) end,
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

Authorization is fail closed. A component check authorizes only when it returns
`true` or `:ok`. `false`, `nil`, malformed return values, exceptions, throws,
and exits all deny access; a binary `{:error, message}` also denies with that
message. When multiple versions share an identity, an unauthorized higher
version is skipped so an authorized lower version can remain visible, while an
explicit request for the unauthorized version is rejected.

## HTTP Behavior

HTTP auth failures use plain bearer challenges:

```text
WWW-Authenticate: Bearer error="invalid_token", error_description="missing credentials"
```

FastestMCP does not serve OAuth discovery, authorization, token, callback, or
protected-resource metadata routes. Applications that need those endpoints
should expose them from their Plug or Phoenix application and pass normalized
auth results into FastestMCP.

## Why This Shape

Phoenix applications usually already own authentication, sessions, user loading,
authorization policy, and audit metadata. Keeping FastestMCP auth as a small
contract avoids a second identity stack while preserving consistent context for
handlers, middleware, tasks, transports, and component visibility.
