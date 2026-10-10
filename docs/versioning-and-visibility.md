# Versioning and Visibility

A tool, resource, or prompt can exist in several versions at once, so callers
that rely on an old contract keep it while new callers get the new one.
Visibility rules hide and show components while the server runs, for every
client or for one session, without changing your server definition.

## When to use these features

Give a component versions when:

- you change its arguments or its results in a way that breaks existing
  callers, and some of them still need the old shape;
- you move callers to a new version one at a time;
- you want to try a new version on your own callers before it becomes the
  default.

Use visibility rules when:

- you switch components off and on while the server runs, such as the tools
  that write during a maintenance window;
- one conversation should work with fewer tools, for example a read-only mode
  that the user turns on;
- you stage a new version and hide it until it is ready.

Don't use versions as deployment labels: a component needs a second version
only while a caller depends on the first.

> #### Visibility is not authorization {: .warning}
>
> Visibility rules don't know who is calling, and they don't last: the
> server-wide rules are cleared when the server stops, and the components they
> hid come back when it starts again. A tool that calls `FastestMCP.Context.enable_components/2`
> can show its session components that you declared `enabled: false`. To
> decide who may see and call a component, use its `authorization:` option;
> see [Authorizing components](auth.md#authorizing-components).

## Versioning components

Add the same name more than once, each time with its own `version:`. A call
without a version runs the highest one, and the `version:` option picks an
exact one:

```elixir
FastestMCP.server("versions-notes")
|> FastestMCP.add_tool("list_notes", fn _args, _ctx -> %{titles: ["Release", "Groceries"]} end,
  version: "1.0.0"
)
|> FastestMCP.add_tool(
  "list_notes",
  fn _args, _ctx ->
    %{notes: [%{id: "1", title: "Release"}, %{id: "2", title: "Groceries"}]}
  end,
  version: "2.0.0"
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("versions-notes", "list_notes")
# => %{notes: [%{id: "1", title: "Release"}, %{id: "2", title: "Groceries"}]}

FastestMCP.call_tool!("versions-notes", "list_notes", %{}, version: "1.0.0")
# => %{titles: ["Release", "Groceries"]}
```

`FastestMCP.Client` takes the same option for tools, resources, and prompts,
and lists show every version, with the version in each entry's `_meta`:

```elixir
client = FastestMCP.Client.connect!({:in_process, "versions-notes"})

FastestMCP.Client.call_tool!(client, "list_notes", %{}, version: "1.0.0").structured_content
# => %{"titles" => ["Release", "Groceries"]}

FastestMCP.Client.list_tools!(client).items
|> Enum.map(&{&1["name"], &1["_meta"]["fastestmcp"]["version"]})
# => [{"list_notes", "1.0.0"}, {"list_notes", "2.0.0"}]
```

Clients that don't know about versions, which is most of them, see the name
once for each version and run the highest when they call it. So keep an old
version only as long as some caller asks for it by number.

These rules hold for every kind of component:

- A version is a string, such as `"2.0.0"`. Versions that are valid semantic
  versions compare as versions, so `"1.10.0"` is higher than `"1.9.0"`.
- A component without a version is lower than any version, and one source of
  components (your server definition, a provider, or the component manager)
  can't mix versioned and unversioned components of the same name.
- When the highest version is hidden from the caller, or its `authorization:`
  denies the caller, a call without `version:` runs the highest version the
  caller may use. A call that names a hidden or denied version fails, for
  example with `:disabled` or `:forbidden` in process. Over MCP, a hidden
  version is unknown to the client (`:not_found`), and a denied one fails with
  `:forbidden`.
- When your server definition, a provider, and the component manager each
  have the same name and version, lists show it once: the one a call runs.

## Hiding and showing components

`FastestMCP.disable_components!/2` hides the components that match a selector
from every client, and `FastestMCP.enable_components!/2` shows them again.
Hidden components disappear from lists, and calling one fails with `:disabled`;
an MCP client gets the error of an unknown component, `:not_found`.
`FastestMCP.reset_component_visibility!/1` removes every rule:

```elixir
FastestMCP.server("visibility-maintenance")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end, tags: ["read"])
|> FastestMCP.add_tool("add_note", fn _args, _ctx -> %{id: "3"} end, tags: ["write"])
|> FastestMCP.add_tool("delete_note", fn _args, _ctx -> %{deleted: "1"} end, tags: ["write"])
|> FastestMCP.start_server!()

:ok = FastestMCP.disable_components!("visibility-maintenance", tags: ["write"])

FastestMCP.list_tools!("visibility-maintenance") |> Enum.map(& &1.name)
# => ["search_notes"]

{:error, error} = FastestMCP.call_tool("visibility-maintenance", "add_note")
error.code
# => :disabled

:ok = FastestMCP.reset_component_visibility!("visibility-maintenance")

FastestMCP.list_tools!("visibility-maintenance") |> Enum.map(& &1.name)
# => ["add_note", "delete_note", "search_notes"]
```

In your application, call them where the decision is made, such as an admin
action that starts maintenance:
`FastestMCP.disable_components!(MyApp.MCPServer, tags: ["write"])`. Each change
notifies connected clients that the list changed; see
[Change notifications](dynamic-components.md#change-notifications).

### Selectors

Both functions take these selectors. A component matches when it matches every
selector you give:

| Selector | Matches |
| --- | --- |
| `names: ["add_note"]` | Components with one of these names; for resources and templates, their URI or URI template |
| `tags: ["write"]` | Components with at least one of these tags |
| `version: "2.0.0"` | That exact version |
| `version: %{gte: "2.0.0"}` | Versions compared with `:eq`, `:gt`, `:gte`, `:lt`, or `:lte`; combine them, as in `%{gte: "1.0.0", lt: "2.0.0"}` |
| `components: [:tool]` | Kinds of components: `:tool`, `:resource`, `:resource_template`, `:prompt` |
| `keys: ["tool:list_notes@1.0.0"]` | One version of one component, by its key |
| `match_all: true` | Every component of the kinds in `components:`, or every component |

A key is the kind, the name, and the version: `"tool:list_notes@1.0.0"`, or
`"tool:search_notes@"` without a version. The kinds are written `tool`,
`resource`, `template`, and `prompt`, as in `"template:notes://{id}@"`. The
maps that `FastestMCP.list_tools!/2` and the other list functions return
carry each component's key as `:key`. A call without any selector matches
nothing.

### Allowlists

With `only: true`, `enable_components!/2` first hides everything of the kinds
in `components:`, then shows the matches. Without `components:`, that hides
every resource and prompt too:

```elixir
FastestMCP.server("visibility-allowlist")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end, tags: ["read"])
|> FastestMCP.add_tool("add_note", fn _args, _ctx -> %{id: "3"} end, tags: ["write"])
|> FastestMCP.add_prompt("summarize_notes", fn _args, _ctx -> "Summarize my notes." end)
|> FastestMCP.start_server!()

:ok =
  FastestMCP.enable_components!("visibility-allowlist",
    tags: ["read"],
    components: [:tool],
    only: true
  )

FastestMCP.list_tools!("visibility-allowlist") |> Enum.map(& &1.name)
# => ["search_notes"]

FastestMCP.list_prompts!("visibility-allowlist") |> Enum.map(& &1.name)
# => ["summarize_notes"]
```

Rules apply in the order you add them, so a later rule overrides an earlier
one for the components both match. A server-wide `enable_components!/2` also
shows components that you declared with `enabled: false`; see
[Enabling and disabling](dynamic-components.md#enabling-and-disabling).

## Per-session visibility

Inside a handler, `FastestMCP.Context.disable_components/2`,
`FastestMCP.Context.enable_components/2`, and
`FastestMCP.Context.reset_visibility/1` change what one session sees, with the
same selectors. Only `2025-11-25` clients have sessions; on `2026-07-28`, these
functions raise (see the note below). For example, a tool can put the current
conversation in a read-only mode:

```elixir
alias FastestMCP.Context

FastestMCP.server("visibility-session")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end, tags: ["read"])
|> FastestMCP.add_tool("add_note", fn _args, _ctx -> %{id: "3"} end, tags: ["write"])
|> FastestMCP.add_tool("read_only_mode", fn _args, ctx ->
  :ok = Context.disable_components(ctx, tags: ["write"])
  "Writing is off for this conversation."
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("visibility-session", "read_only_mode", %{}, session_id: "chat-1")
# => "Writing is off for this conversation."

FastestMCP.list_tools!("visibility-session", session_id: "chat-1") |> Enum.map(& &1.name)
# => ["read_only_mode", "search_notes"]

FastestMCP.list_tools!("visibility-session", session_id: "chat-2") |> Enum.map(& &1.name)
# => ["add_note", "read_only_mode", "search_notes"]
```

The rules of a session last until the session ends or the handler resets
them, and a session whose list changes receives a list-changed notification.
Server-wide rules come first: a session can hide more, and can show components
declared `enabled: false`, but it can't show a component that
`FastestMCP.disable_components/2` hid.

> #### Sessions exist only on `2025-11-25` {: .info}
>
> Session rules are kept in [session state](context.md#session-state), so
> they last as long as a session lasts. A `2026-07-28` request has no session
> to keep them, so the three functions raise an `:internal_error` that says
> the request needs a `2025-11-25` session; so does an in-process call without
> `session_id:`. In process, calls that pass the same `session_id:` share
> rules, as above. To change what every client sees, use
> `FastestMCP.disable_components!/2` and its siblings.

## Details

### How a call picks a version

A call collects the components with its name, or for a resource read the
resources and templates that match the URI, from your server definition, its
providers, and the component manager. It sorts them from the highest version
down, and runs the first one that the caller may see and use. Resources with
the exact URI come before templates.

Two versions compare as semantic versions when both parse as one, such as
`"1.2.0"`, and as plain strings otherwise, so `"2024-11"` is higher than
`"2024-05"`. When versions tie, the order of the sources decides; see
[The same name in several sources](dynamic-components.md#the-same-name-in-several-sources).
A version can't contain `@`, which separates it from the name in a key.

### Versions on the wire

`FastestMCP.Client` sends the `version:` option as
`_meta.fastestmcp.version` in the parameters of `tools/call`,
`resources/read`, and `prompts/get`, and other clients can do the same. Each
entry of a list carries its version as `_meta.fastestmcp.version`.

### The order of rules

For each component, FastestMCP applies, in order: the server transforms, the
server-wide rules in the order you added them, and the rules of the session.
Then the component must be enabled, visible to the caller's audience, and
allowed by its `authorization:` checks. A component that fails a step is left
out of lists, and an in-process call to it fails with that step's error:
`:filtered` for a transform that drops it, `:disabled`, `:not_visible`, or
`:forbidden`. Over MCP, the first three answer like an unknown component,
`:not_found`, so a client can't tell a hidden component from a missing one;
`:forbidden` stays, so that an OAuth client can ask for the scopes it lacks.

### Audiences

The `visibility:` option of a component lists the audiences that see it, by
default `[:model]`. MCP clients are always the `:model` audience. In-process
calls pass `audience:`, also `:model` by default, so a component with
`visibility: [:app]` is hidden from MCP clients but available to your own
code:

```elixir
FastestMCP.server("visibility-audience")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_tool("rebuild_index", fn _args, _ctx -> %{rebuilt: true} end,
  visibility: [:app]
)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("visibility-audience") |> Enum.map(& &1.name)
# => ["search_notes"]

FastestMCP.call_tool!("visibility-audience", "rebuild_index", %{}, audience: :app)
# => %{rebuilt: true}
```

### Where rules live

Server-wide rules belong to the running server: they survive a restart of its
processes after a crash, and stopping the server, as `FastestMCP.stop_server/1`
does, clears them. Session rules are part of the session's state. A
server-wide change notifies every listening client about the kinds of
components it selects; a session change notifies only that session, and only
when what it sees changed.

## See also

- [Dynamic Components](dynamic-components.md): adding, removing, and
  switching components while the server runs
- [Authentication and Authorization](auth.md): deciding who may use a
  component
- [Transforms](transforms.md): rewriting or hiding components with code
- [Context](context.md): sessions and session state
