# Versioning and Visibility

FastestMCP resolves tools, resources, resource templates, and prompts through
two explicit catalog layers:

1. version selection
2. visibility and authorization policy

That same resolution model is used for in-process calls, HTTP, stdio, mounted
providers, and connected clients.

## Versioning

Register multiple versions of the same component with `version:`:

```elixir
server =
  FastestMCP.server("versioning")
  |> FastestMCP.add_tool("calc", fn _args, _ctx -> 1 end, version: "1.0.0")
  |> FastestMCP.add_tool("calc", fn _args, _ctx -> 2 end, version: "2.0.0")
```

By default, FastestMCP picks the highest visible version:

```elixir
FastestMCP.call_tool("versioning", "calc", %{})
# => 2
```

Callers can request one exact version:

```elixir
FastestMCP.call_tool("versioning", "calc", %{}, version: "1.0.0")
# => 1
```

Connected clients use the same option:

```elixir
FastestMCP.Client.call_tool(client, "calc", %{}, version: "1.0.0")
# => 1
```

On the wire, FastestMCP sends the version through `_meta.fastestmcp.version`, so
transport and direct calls resolve the same component version.

## Versioning Rules

FastestMCP keeps version rules strict:

- the highest visible version wins by default
- exact versions remain callable
- version strings cannot contain `@`
- you cannot mix versioned and unversioned definitions for the same identifier

If the newest version is globally hidden, default resolution falls back to the
highest version that is still visible.

## Server-Scoped Visibility

Use the public server visibility API to change the catalog for every session:

```elixir
:ok =
  FastestMCP.disable_components("catalog",
    tags: ["internal"],
    components: [:tool]
  )

:ok =
  FastestMCP.enable_components("catalog",
    tags: ["finance"],
    components: [:tool],
    only: true
  )

:ok = FastestMCP.reset_component_visibility("catalog")
```

Selectors are shared across `enable_components/2` and `disable_components/2`:

- `names: ["calc"]`
- `keys: ["tool:calc@2.0.0"]`
- `tags: ["finance"]`
- `version: %{eq: "2.0.0"}`
- `version: %{gte: "2.0.0"}`
- `components: [:tool]`
- `match_all: true`
- `only: true`

`only: true` is allowlist sugar. It means “disable everything in this component
set first, then re-enable the matching subset.”

## Session-Scoped Visibility

Use `%FastestMCP.Context{}` when one request should reshape the catalog for
just that session:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("session-visibility")
  |> FastestMCP.add_tool("focus_finance", fn _arguments, ctx ->
    :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool], only: true)
    %{ok: true}
  end)
  |> FastestMCP.add_tool("hide_internal", fn _arguments, ctx ->
    :ok = Context.disable_components(ctx, tags: ["internal"], components: [:tool])
    %{ok: true}
  end)
  |> FastestMCP.add_tool("reset_visibility", fn _arguments, ctx ->
    :ok = Context.reset_visibility(ctx)
    %{ok: true}
  end)
```

Session rules persist for that session until they are reset or the session ends.

## Global vs Session Precedence

Server-scoped visibility is authoritative.

That means:

- a session can narrow the globally visible set
- a session can allowlist within the globally visible set
- a session cannot re-expose a component the server already disabled

This matters most for versioned tools. If version `2.0.0` is globally hidden,
default resolution falls back to the highest visible version instead of letting
the session re-enable `2.0.0`.

## Notifications

FastestMCP emits list-changed notifications when the visible catalog changes:

- `notifications/tools/list_changed`
- `notifications/resources/list_changed`
- `notifications/prompts/list_changed`

Those notifications are delivered to connected streamable HTTP session streams.
Server-scoped visibility updates reuse the same notification path as session
visibility updates.

## When To Use These Features

Use versioning when:

- a component must keep an older contract alive
- you are migrating clients gradually
- mounted or generated providers expose multiple compatible revisions

Use visibility when:

- the server needs a stable allowlist or denylist
- one session should see a narrower catalog than another
- you want to stage versions or tags without renaming components

Do not use versioning as deployment labeling, and do not use visibility as a
replacement for authorization policy.

## Related Guides

- [Tools](tools.md)
- [Components](components.md)
- [Transforms](transforms.md)
- [Providers and Mounting](providers-and-mounting.md)
