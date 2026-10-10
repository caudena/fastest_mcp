# Lifespans and Dependencies

A lifespan runs when your MCP server starts and stops, and gives handlers what
it set up. A dependency gives a handler a value made for its request, and
cleans it up when the request ends. In a Phoenix app, you often need neither.

## When you need them

Handlers are ordinary functions that run inside your application. They can call
your Phoenix contexts, your `Repo`, and any process your application
supervises, just as a controller does: the handlers in
[Getting Started](getting-started.md) call `MyApp.Notes` directly. Reach for a
lifespan or a dependency only when a value has a lifetime of its own:

| You need | Use |
| --- | --- |
| Your contexts, `Repo`, or a process your application supervises | Nothing: call it from the handler |
| Something set up when the MCP server starts and released when it stops | [A lifespan](#lifespans) |
| A value made for each request, often released when the request ends | [A dependency](#dependencies) |
| Values kept between requests | [Session state or an application session](context.md#choosing-where-to-keep-state) |

## Lifespans

A lifespan is a function that runs once, when the server starts, before it
accepts requests. The map it returns is available to every handler as
`ctx.lifespan_context`:

```elixir
FastestMCP.server("notes-titles")
|> FastestMCP.add_lifespan(fn _server ->
  titles = :ets.new(:note_titles, read_concurrency: true)
  # Load the titles from your database here.
  :ets.insert(titles, [{"1", "Release"}, {"2", "Groceries"}])
  %{titles: titles}
end)
|> FastestMCP.add_tool(
  "note_title",
  fn %{"id" => id}, ctx ->
    case :ets.lookup(ctx.lifespan_context.titles, id) do
      [{^id, title}] -> title
      [] -> raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
    end
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-titles", "note_title", %{"id" => "1"})
# => "Release"
```

The lifespan runs in a process that lives as long as the server. That process
owns the ETS table above, so handlers can read the table while the server runs,
and the table goes away when the server stops. The function receives the server
definition, so it can use `server.name`. In a server module, add the lifespan
in `server/1`, as in
`base_server(opts) |> FastestMCP.add_lifespan(&__MODULE__.load_titles/1)`.

### Cleaning up

To release what a lifespan set up, return the map together with a cleanup
function:

```elixir
FastestMCP.server("notes-exports")
|> FastestMCP.add_lifespan(fn server ->
  dir = Path.join(System.tmp_dir!(), "#{server.name}-exports")
  File.mkdir_p!(dir)
  {%{exports_dir: dir}, fn -> File.rm_rf!(dir) end}
end)
|> FastestMCP.add_tool(
  "export_note",
  fn %{"id" => id}, ctx ->
    path = Path.join(ctx.lifespan_context.exports_dir, "note-#{id}.md")
    File.write!(path, "# Note #{id}\n")
    path
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

path = FastestMCP.call_tool!("notes-exports", "export_note", %{"id" => "1"})
File.exists?(path)
# => true

FastestMCP.stop_server!("notes-exports")
File.exists?(path)
# => false
```

The cleanup function takes no arguments, or the map. It runs when the server
stops: when your application shuts down, or when you call
`FastestMCP.stop_server/1`. A server that restarts after a failure runs its
cleanups, then its lifespans again.

You can add several lifespans. They start in the order you add them, and their
maps merge into one `ctx.lifespan_context`, in which a later lifespan's key
replaces an earlier one's. Their cleanups run in the reverse order, so each
lifespan is cleaned up before the ones it may rely on.

### When startup fails

A lifespan that raises stops the server from starting. The cleanups of the
lifespans that had already started still run:

```elixir
FastestMCP.server("notes-missing-index")
|> FastestMCP.add_lifespan(fn _server -> raise "the search index is missing" end)
|> FastestMCP.start_server()
# => {:error, %RuntimeError{message: "the search index is missing"}}
```

Under your application's supervisor, a server that fails to start stops your
application from starting, as any child that fails to start does. A lifespan
also delays startup by as long as it runs, so keep slow work, such as warming a
large cache, out of it, and give that work to a process that your application
supervises.

### Lifespans and supervised processes

A lifespan is not a supervisor. A process that your whole application uses,
such as your `Repo`, a PubSub, or an HTTP client pool, belongs in your
application's supervision tree, before the MCP server: it restarts on its own,
and controllers and jobs can use it too.

A lifespan suits what belongs to the MCP server alone: work to do when it
starts, and resources that only its handlers use.

> #### Processes that a lifespan links to {: .warning}
>
> A process that a lifespan starts with a `start_link` function is linked to
> the server. When that process crashes, the whole server restarts: it loses
> its sessions, their state, and its running background tasks, and its
> lifespans run again. A process that finishes normally, such as a task from
> `Task.start_link/1` that returns, leaves the server running. Start work that
> can fail under your application's supervisor instead.

## Dependencies

A dependency is a value made for one request. You register a resolver under a
name, and `Context.dependency/2` runs it the first time a handler asks for the
name during a request. When the resolver returns `{:ok, value, cleanup}`, the
cleanup runs after the request, even if the handler raises:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-workdir")
|> FastestMCP.add_dependency(:workdir, fn ->
  dir = Path.join(System.tmp_dir!(), "notes-export-#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)
  {:ok, dir, &File.rm_rf!/1}
end)
|> FastestMCP.add_tool("export_notes", fn _args, ctx ->
  dir = Context.dependency(ctx, :workdir)
  File.write!(Path.join(dir, "release.md"), "# Release\nShip the notes server on Friday\n")
  # Zip the directory and upload the archive here.
  %{dir: dir, files: File.ls!(dir)}
end)
|> FastestMCP.start_server!()

%{dir: dir, files: files} = FastestMCP.call_tool!("notes-workdir", "export_notes")
files
# => ["release.md"]

File.exists?(dir)
# => false
```

During one request, the value is resolved once: every later
`Context.dependency/2` call for the name returns the same value, so helper
functions can ask for it too. The next request gets a new one. A dependency
that the handler never asks for is never resolved.

### Using the request

A resolver can take the context, to build the value from the request. Here
each request loads the caller's account:

```elixir
alias FastestMCP.Context

users = %{"alice" => %{name: "Alice", notebook: "work"}}

FastestMCP.server("notes-current-user")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"alice-token" => %{principal: %{"sub" => "alice"}, scopes: ["notes"]}}
)
|> FastestMCP.add_dependency(:current_user, fn ctx ->
  # In your app, for example: MyApp.Accounts.get_user!(ctx.principal["sub"])
  Map.fetch!(users, ctx.principal["sub"])
end)
|> FastestMCP.add_tool("my_notebook", fn _args, ctx ->
  Context.dependency(ctx, :current_user).notebook
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-current-user", "my_notebook", %{},
  auth_input: %{"authorization" => "Bearer alice-token"}
)
# => "work"
```

The handler doesn't repeat how to find the user, and however many of your
functions ask for `:current_user` during a request, it is loaded once.

### When a resolver fails

A resolver that raises fails the request, as a handler that raises does. A
resolver can also return `{:error, %FastestMCP.Error{}}` to fail the request
with that error, or `{:error, reason}` to fail it with an `:internal_error`.
Asking for a name that the server doesn't have raises an `ArgumentError`.

## Lifespans or dependencies?

| | Lifespan | Dependency |
| --- | --- | --- |
| Runs | Once, when the server starts | The first time a request asks for it |
| Its value | `ctx.lifespan_context`, the same in every request | `Context.dependency(ctx, name)`, one for each request |
| Cleans up | When the server stops | When the request ends |
| If it fails | The server doesn't start | That request fails |
| Use it for | Caches, configuration, resources for the server's lifetime | The current user, temporary files, a connection for one request |

Use neither for a value that a handler can compute in a line or two, or for a
service your application already runs. Values that must last between requests
belong in [session state or an application session](context.md#choosing-where-to-keep-state),
or in your database.

## Details

### Lifespan return values

| The lifespan returns | `ctx.lifespan_context` gets | Cleanup |
| --- | --- | --- |
| `map` or `{:ok, map}` | The map | None |
| `{map, cleanup}` or `{:ok, map, cleanup}` | The map | `cleanup`, of arity 0 or 1 (the map) |
| `nil` or `{:ok, nil}` | Nothing | None |

Anything else, `{:error, reason}` included, stops the server from starting with
`{:error, {:invalid_lifespan_result, value}}`.

`FastestMCP.add_lifespan/3` takes the cleanup as a separate exit function, which
may be `nil` or take no arguments, the map, or the server definition and the
map. When the lifespan returns a cleanup of its own, the exit function is not
used. `FastestMCP.Lifespan.new/2` builds the same pair as a value, and
`FastestMCP.server/2` accepts lifespans in its `lifespans:` option.

### Dependency resolvers and cleanups

A resolver takes no arguments, or the context. It returns:

| The resolver returns | The handler gets | Cleanup |
| --- | --- | --- |
| `value` or `{:ok, value}` | `value` | None |
| `{:ok, value, cleanup}` | `value` | `cleanup` |
| `{:error, %FastestMCP.Error{}}` | The request fails with that error | None |
| `{:error, reason}` | The request fails with an `:internal_error` | None |

`{value, cleanup}` is a plain value here, unlike for lifespans. A cleanup takes
no arguments, the value, or the value and the context. Cleanups run after the
handler returns or raises, in the reverse order of resolution. A cleanup that
fails is logged and doesn't change the result.

`Context.register_cleanup/2` registers a cleanup from inside a handler, without
a dependency: a function of no arguments or of the context, run when the
request ends.

Names may be atoms or strings: `:workdir` and `"workdir"` are the same
dependency. `Context.dependencies/1` lists the names, and `FastestMCP.server/2`
accepts a map of resolvers in its `dependencies:` option.

### Other processes and background tasks

Dependency values and their cleanups belong to the process that runs the
handler. A `Task` that the handler starts and that calls
`Context.dependency/2` resolves the dependency again, and its cleanup never
runs, so resolve dependencies in the handler and pass the values on.

A [background task](background-tasks.md) resolves each dependency once for the
task, and runs the cleanups when the task finishes. Its handler sees the same
`ctx.lifespan_context` as other requests.

### Mounted servers

When you [mount a server](providers-and-mounting.md) into another, the mounted
server's lifespans start after the parent's own, and its cleanups run before
the parent's. Its handlers see the mounted server's `ctx.lifespan_context`, not
the parent's. The exception is the lifespan of a
[server extension](extensions.md): it runs once for the whole server and keeps
its state under the extension's identifier, where the handlers of every server
that uses the extension find it.

A mounted server's handlers resolve its own dependencies, and the dependencies
of the servers it is mounted in: when both declare a name, the mounted server's
resolver wins in its handlers, and the parent's in the parent's handlers.

## See also

- [Context](context.md): state, logging, and progress in handlers
- [Background Tasks](background-tasks.md): long work that clients follow
- [Providers and Mounting](providers-and-mounting.md): combining servers
- [Getting Started](getting-started.md): a Phoenix MCP server, step by step
