# Pagination

FastestMCP supports cursor pagination for list operations without changing the
default return shape.

By default:

- `FastestMCP.list_tools/2` returns a plain list
- `FastestMCP.list_resources/2` returns a plain list
- `FastestMCP.list_resource_templates/2` returns a plain list
- `FastestMCP.list_prompts/2` returns a plain list

When you opt into pagination with `page_size:`, the return value becomes a page
map with `:items` and `:next_cursor`.

## Why Pagination Exists

Small servers do not need pagination, so the direct Elixir API stays simple by
default. Large servers do. Pagination exists so the same runtime can scale from
"a handful of tools" to "a large generated catalog" without forcing every call
site to unwrap a paging object when it is not needed.

## Direct API

```elixir
server_name = "pagination"

FastestMCP.list_tools(server_name)
#=> [%Tool{}, %Tool{}, ...]

%{items: tools, next_cursor: cursor} =
  FastestMCP.list_tools(server_name, page_size: 20)
```

Fetch the next page by reusing the returned cursor:

```elixir
%{items: next_page, next_cursor: next_cursor} =
  FastestMCP.list_tools(server_name, page_size: 20, cursor: cursor)
```

The cursor is opaque. Treat it as a token to pass back to the runtime, not as a
stable public format.

## What Gets Paginated

Pagination applies to list surfaces:

- tools
- resources
- resource templates
- prompts

It does not change `call_tool`, `read_resource`, or `render_prompt`.

## Transport Behavior

The MCP wire is intentionally different from the Elixir convenience option:

- the server owns a page size of 100
- a first request omits `cursor`
- continuation sends only the opaque `cursor`
- the result includes `nextCursor` only when another page exists
- a legacy top-level `pageSize` field is ignored and never controls server work

Wire cursors are signed and bound to the list method, runtime generation,
principal/visibility/filter fingerprint, and last stable component identity.
They are limited to 4 KiB and use keyset continuation rather than offset
slicing. A cursor cannot be moved between methods, sessions with different
visibility, principals, or runtime generations.

Providers may implement the optional page callback to filter and limit at the
source. Existing providers use the streaming fallback, so the wire contract
does not require every provider to change at once.

## Example

```elixir
server =
  Enum.reduce(1..5, FastestMCP.server("pagination"), fn index, acc ->
    acc
    |> FastestMCP.add_tool("tool_#{index}", fn _args, _ctx -> index end)
    |> FastestMCP.add_resource("data://resource/#{index}", fn _args, _ctx -> index end)
    |> FastestMCP.add_prompt("prompt_#{index}", fn _args, _ctx -> "prompt-#{index}" end)
  end)

{:ok, _pid} = FastestMCP.start_server(server)

%{items: tools_page_1, next_cursor: cursor} =
  FastestMCP.list_tools("pagination", page_size: 2)

%{items: tools_page_2, next_cursor: nil} =
  FastestMCP.list_tools("pagination", page_size: 3, cursor: cursor)
```

## Invalid Input

Pagination raises a normalized bad-request error when:

- `page_size` is not a positive integer
- the cursor is invalid

The transport also rejects signed cursors that are tampered with or belong to a
different method, runtime generation, principal, visibility/filter scope, or
stable keyset.

That makes list behavior consistent with the rest of the runtime.

## Why This Shape

FastestMCP makes pagination opt-in instead of mandatory.

That keeps the direct Elixir surface pleasant for small servers while still
matching protocol needs for larger catalogs. The runtime owns cursor encoding
and decoding so call sites do not need to understand pagination internals.

## Related Guides

- [Components](components.md)
- [Providers and Mounting](providers-and-mounting.md)
- [Versioning and Visibility](versioning-and-visibility.md)
