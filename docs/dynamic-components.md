# Dynamic Components

A running server can gain and lose tools, resources, and prompts without a
restart or a deploy. You make these changes through the server's component
manager, and connected clients are told that the list changed. Change
components at runtime when what your server offers depends on what happens in
your application: the tools of an integration that an admin connects, prompt
templates that staff edit, a tool behind a feature flag, or saved reports that
each tenant defines.

```elixir
FastestMCP.server("dynamic-notes")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool(
    "dynamic-notes",
    "export_notes",
    fn _args, _ctx -> %{file: "notes.md"} end,
    description: "Export every note as one Markdown file."
  )

FastestMCP.list_tools!("dynamic-notes") |> Enum.map(& &1.name)
# => ["export_notes", "search_notes"]

FastestMCP.call_tool!("dynamic-notes", "export_notes")
# => %{file: "notes.md"}

{:ok, [_removed]} = FastestMCP.ComponentManager.remove_tool("dynamic-notes", "export_notes")

FastestMCP.list_tools!("dynamic-notes") |> Enum.map(& &1.name)
# => ["search_notes"]
```

## Adding and removing at runtime

Every running server has a component manager, `FastestMCP.ComponentManager`.
Its functions take the name of a running server, such as `MyApp.MCPServer`,
or the manager that `FastestMCP.component_manager!/1` returns:

| To | Call |
| --- | --- |
| Add a component | `add_tool/4`, `add_resource/4`, `add_resource_template/4`, `add_prompt/4` |
| Remove one | `remove_tool/3`, `remove_resource/3`, `remove_resource_template/3`, `remove_prompt/3` |
| Switch one off or on | `disable_tool/3`, `enable_tool/3`, and the same for the other kinds; see [Enabling and disabling](#enabling-and-disabling) |
| See what was added | `list/3` and `get/4` |

The `add_*` functions take the same handler and options as
`FastestMCP.add_tool/4` and its siblings, plus `on_duplicate:` (see
[Duplicate names](#duplicate-names)), and return `{:ok, component}`. A
component added at runtime works like one in your server definition:
authorization, middleware, visibility rules, and versions apply to it.

In your application, call the manager where the change happens, for example
in the context that saves a prompt that staff edit in your admin pages:

```elixir
# In lib/my_app/prompts.ex
def publish(%Prompt{} = prompt) do
  FastestMCP.ComponentManager.add_prompt(
    MyApp.MCPServer,
    prompt.name,
    fn _args, _ctx -> prompt.body end,
    description: prompt.description,
    on_duplicate: :replace
  )
end
```

`remove_*` removes every version of the name, or one version with `version:`,
and returns `{:ok, removed}` or `{:error, :not_found}`.

### Components for one tenant

Components that the manager adds are part of the server, so every client can
see them. Give a component that belongs to one tenant a name of its own and an
`authorization:` check, and other tenants never see it:

```elixir
# In lib/my_app/reports.ex
def publish(%Report{} = report, %Organization{} = org) do
  FastestMCP.ComponentManager.add_tool(
    MyApp.MCPServer,
    "#{org.slug}_#{report.slug}",
    fn _args, _ctx -> run(report) end,
    description: report.description,
    authorization: fn authz -> authz.principal["org_id"] == org.id end,
    on_duplicate: :replace
  )
end
```

[Authorizing components](auth.md#authorizing-components) explains the checks.

### Changes last while the server runs

The manager keeps its components, and the server-wide visibility rules, in the
running server. They survive a crash of another process in the server, which
the server recovers from by restarting its processes, the manager aside. When
the server stops, they are gone, and it starts again from its definition: after
`FastestMCP.stop_server/1`, when your application stops, or when crashes repeat
until the supervisor above the server starts it over. Keep the source of truth
in your database and add the components again after the server starts.

When a set of components must always match your data, such as one tool for
each row of a table, write a custom provider instead: it reads your data on
each request, so nothing is lost on a restart. See
[Custom providers](providers-and-mounting.md#custom-providers).

## Enabling and disabling

A disabled component stays on the server but is hidden: lists leave it out,
and an in-process call fails with `:disabled`; an MCP client gets
`:not_found`, as for a component that doesn't exist. To ship a component
switched off, give it `enabled: false`, and enable it when it is ready:

```elixir
FastestMCP.server("dynamic-flags")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_tool("summarize_week", fn _args, _ctx -> %{summary: "A quiet week."} end,
  enabled: false
)
|> FastestMCP.start_server!()

{:error, error} = FastestMCP.call_tool("dynamic-flags", "summarize_week")
error.code
# => :disabled

:ok = FastestMCP.enable_components!("dynamic-flags", names: ["summarize_week"])

FastestMCP.call_tool!("dynamic-flags", "summarize_week")
# => %{summary: "A quiet week."}
```

`FastestMCP.enable_components!/2` and `FastestMCP.disable_components!/2` work on
every component of the server, wherever it comes from, and select them by
name, tag, version, or kind;
[Hiding and showing components](versioning-and-visibility.md#hiding-and-showing-components)
describes them. To switch components off for one conversation only, see
[Per-session visibility](versioning-and-visibility.md#per-session-visibility).

For a component that the manager added, `disable_tool/3` and `enable_tool/3`
(and `disable_resource/3`, `enable_prompt/3`, and so on) switch it off and on,
all its versions or one with `version:`:

```elixir
FastestMCP.server("dynamic-toggle")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool("dynamic-toggle", "export_notes", fn _args, _ctx ->
    %{file: "notes.md"}
  end)

{:ok, [_disabled]} = FastestMCP.ComponentManager.disable_tool("dynamic-toggle", "export_notes")

FastestMCP.list_tools!("dynamic-toggle") |> Enum.map(& &1.name)
# => ["search_notes"]

{:ok, [_enabled]} = FastestMCP.ComponentManager.enable_tool("dynamic-toggle", "export_notes")

FastestMCP.list_tools!("dynamic-toggle") |> Enum.map(& &1.name)
# => ["export_notes", "search_notes"]
```

These functions see only the components that the manager added; for any other
component they return `{:error, :not_found}`.

## Duplicate names

Within one source of components (your server definition, one provider, or the
component manager), a name or URI can be used once for each version. The
`on_duplicate:` option decides what happens to a second one:

| `on_duplicate:` | A second component with the same name and version |
| --- | --- |
| `:error` (the default) | Raises `ArgumentError` |
| `:replace` | Replaces the first |
| `:warn` | Replaces the first and logs a warning |
| `:ignore` | Is dropped; the first stays |

Set it for the server definition with `FastestMCP.server/2`; the component
manager uses the server's setting unless an `add_*` call passes its own. A
`FastestMCP.Providers.Local` provider takes it in `new/1`:

```elixir
FastestMCP.server("dynamic-duplicates")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool("dynamic-duplicates", "export_notes", fn _args, _ctx ->
    %{format: "markdown"}
  end)

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool(
    "dynamic-duplicates",
    "export_notes",
    fn _args, _ctx -> %{format: "html"} end,
    on_duplicate: :replace
  )

FastestMCP.call_tool!("dynamic-duplicates", "export_notes")
# => %{format: "html"}
```

Without `on_duplicate: :replace`, the second call would raise `ArgumentError`
with the message `tool "export_notes" is already defined without a version`.
One source also can't mix a versioned and an unversioned component of the
same name; that raises `ArgumentError` whatever the policy.

### The same name in several sources

Your server definition, its providers, and the component manager can each have
a component with the same name. They don't replace each other: a call runs the
highest version that the caller may see, so a component the manager adds with
a higher `version:` overrides one from your definition, and disabling or
removing it brings the original back:

```elixir
FastestMCP.server("dynamic-override")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{engine: "basic"} end)
|> FastestMCP.start_server!()

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool(
    "dynamic-override",
    "search_notes",
    fn _args, _ctx -> %{engine: "full-text"} end,
    version: "2.0.0"
  )

FastestMCP.call_tool!("dynamic-override", "search_notes")
# => %{engine: "full-text"}

{:ok, [_removed]} = FastestMCP.ComponentManager.remove_tool("dynamic-override", "search_notes")

FastestMCP.call_tool!("dynamic-override", "search_notes")
# => %{engine: "basic"}
```

When versions tie, your definition wins, then providers in the order you added
them, then the component manager, and lists show the name once: the component
that a call runs. So give an override a higher version, which wins over your
definition.
[Versioning components](versioning-and-visibility.md#versioning-components)
describes how versions compare.

## Change notifications

When the components on offer change, FastestMCP notifies connected clients
with `notifications/tools/list_changed`, `notifications/resources/list_changed`,
or `notifications/prompts/list_changed`, and clients list the components
again. A notification follows:

- every component that the component manager adds, removes, enables, or
  disables;
- every call of `FastestMCP.enable_components/2` and
  `FastestMCP.disable_components/2`, and a call of
  `FastestMCP.reset_component_visibility/1` that clears rules; these notify
  every listening client about the kinds of components they select, even a
  client whose list didn't change;
- a per-session visibility change, which notifies only that session, and only
  when what it sees changed;
- every call of `FastestMCP.notify_list_changed/2`, for the kinds it names,
  which is how a [custom provider](providers-and-mounting.md#custom-providers)
  announces that its components changed.

How a client receives them depends on its protocol version. On `2026-07-28`, a
client opens a `subscriptions/listen` request that names the lists it follows;
the server acknowledges the filter and from then on sends a notification for
every change. On `2025-11-25`, notifications travel in the client's session:
over HTTP on the session's event stream, and over stdio on the connection.
[Other notifications](client-callbacks.md#other-notifications) shows
`FastestMCP.Client` following the tool list as a component is added.

A server offers clients tools, resources, and prompts even while it has none
of a kind, so a server that starts without prompts can add the first one at
runtime, and the clients that connected earlier list it after the
notification. The [response caching](middleware.md#response-caching)
middleware drops what it kept of a kind when that kind changes, so its
clients see the change at once.

## Details

### What the component manager manages

The manager holds only the components added through it. It doesn't see the
components of your server definition or of providers, so it can't remove or
disable them; hide those with
[visibility rules](versioning-and-visibility.md#hiding-and-showing-components)
instead. `list/3` returns the manager's components of one kind (`:tool`,
`:resource`, `:resource_template`, or `:prompt`), and leaves out disabled ones
unless you pass `include_disabled: true`. `get/4` returns the highest enabled
version with a name, or the version that `version:` names, or `nil`; it takes
`include_disabled:` too.

| Function | Returns |
| --- | --- |
| `add_tool/4` and the other `add_*` functions | `{:ok, component}`; the existing component under `on_duplicate: :ignore`; raises `ArgumentError` for a rejected duplicate |
| `remove_tool/3` and the other `remove_*` functions | `{:ok, removed}` or `{:error, :not_found}` |
| `enable_tool/3`, `disable_tool/3`, and the others | `{:ok, changed}` or `{:error, :not_found}` |
| `list/3` | A list of components |
| `get/4` | A component or `nil` |

A server name that isn't running raises `ArgumentError`. The manager is also a
provider: FastestMCP adds it after the providers of your server definition,
which is why its components come last when versions tie.

### Notification delivery

On `2025-11-25`, a session receives list-change notifications only while it
listens: over HTTP, while the client keeps the session's `GET` event stream
open; over stdio, while the connection is open. The server's capabilities
offer `listChanged` for tools, resources, and prompts whenever it can send
notifications, that is over HTTP and stdio, and with an in-process
`FastestMCP.Client`.

On `2026-07-28`, the `subscriptions/listen` filter takes `toolsListChanged`,
`resourcesListChanged`, and `promptsListChanged`. The server acknowledges the
filter with `notifications/subscriptions/acknowledged` and sends notifications
while the request stays open. A subscription has no session, so a per-session
visibility change never reaches it.

A notification names only the kind of list, so the client lists that kind
again. `FastestMCP.Client` drops what it cached of that list when one
arrives.

## See also

- [Versioning and Visibility](versioning-and-visibility.md): versions, and
  hiding components for every client or one session
- [Providers and Mounting](providers-and-mounting.md): components from other
  sources, and custom providers
- [Tools](tools.md), [Resources](resources.md), and [Prompts](prompts.md): the
  options that `add_*` takes
- `FastestMCP.ComponentManager`
