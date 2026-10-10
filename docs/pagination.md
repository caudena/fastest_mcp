# Pagination

Lists of tools, resources, resource templates, and prompts can grow long, so
MCP sends them a page at a time. FastestMCP lists components in three places,
and each returns its own shape:

| You call | You get | For more |
| --- | --- | --- |
| `FastestMCP.list_tools/2`, in process | Every tool, as a list | Nothing to do; pass `page_size:` to get pages instead |
| `FastestMCP.Client.list_tools/2` | One page from the server: `%{items: items, next_cursor: cursor}` | Pass `cursor:`, or call `FastestMCP.Client.list_all_tools/2` |
| `FastestMCP.ClientGroup.list_tools/2` | Every tool of every member, as a list | Nothing to do |

Resources, resource templates, and prompts work the same way. A page holds
`items`, the components on the page, and `next_cursor`, an opaque string that
you pass back as `cursor:` for the next page, or `nil` on the last page.

## Listing locally

`FastestMCP.list_tools/2` and its siblings return every component the caller
can see:

```elixir
server =
  Enum.reduce(1..5, FastestMCP.server("paging-demo"), fn n, server ->
    FastestMCP.add_tool(server, "tool_#{n}", fn _args, _ctx -> n end)
  end)

FastestMCP.start_server!(server)

FastestMCP.list_tools!("paging-demo") |> Enum.map(& &1.name)
# => ["tool_1", "tool_2", "tool_3", "tool_4", "tool_5"]
```

Each item is a map with atom keys that describes the component, such as its
`name`, `description`, and `input_schema`. Components are listed in name order.

Pass `page_size:` to get one page at a time, and the `next_cursor` of each page
as `cursor:` for the next:

```elixir
%{items: page, next_cursor: cursor} = FastestMCP.list_tools!("paging-demo", page_size: 2)
Enum.map(page, & &1.name)
# => ["tool_1", "tool_2"]

%{items: page, next_cursor: cursor} =
  FastestMCP.list_tools!("paging-demo", page_size: 2, cursor: cursor)

Enum.map(page, & &1.name)
# => ["tool_3", "tool_4"]

%{items: page, next_cursor: cursor} =
  FastestMCP.list_tools!("paging-demo", page_size: 2, cursor: cursor)

{Enum.map(page, & &1.name), cursor}
# => {["tool_5"], nil}
```

- `FastestMCP.list_resources/2`, `FastestMCP.list_resource_templates/2`, and
  `FastestMCP.list_prompts/2` take the same options.
- A `page_size:` that isn't a positive integer, or a cursor these functions
  didn't return, fails with `:bad_request`. A `cursor:` without `page_size:` is
  ignored.
- To list as a particular caller, pass its credentials as `auth_input:`; lists
  leave out what the caller may not use (see
  [Authorizing components](auth.md#authorizing-components)).

`FastestMCP.list_tasks/2` always returns a page, with the key `tasks` instead
of `items`; see [Running tasks locally](background-tasks.md#running-tasks-locally).

## Listing from a client

Over MCP, the server decides how many items a page holds, and a FastestMCP
server sends up to 100. `FastestMCP.Client.list_tools/2` returns one page, and
`FastestMCP.Client.list_all_tools/2` follows every page and returns one list;
[Listing and paging](client.md#listing-and-paging) shows both.

- Items are the server's descriptions, with string keys such as `"name"` and
  `"inputSchema"`. A page can hold more keys than `items` and `next_cursor`,
  such as caching hints, so match on the two you need.
- The client has no `page_size:` option; passing one raises `ArgumentError`.
- The `list_all_*` functions stop with an `:overloaded` error after 256 pages
  or 100,000 items, which `max_pages:` and `max_items:` change. A server that
  sends the same cursor twice fails the listing with `:invalid_request`.
- Pass a cursor back to the server that issued it, from the same client;
  [Cursors on the wire](#cursors-on-the-wire) explains when a server rejects
  one.

`FastestMCP.Client.list_tasks/2` returns pages of tasks in the same shape; see
[Remote tasks](client-callbacks.md#remote-tasks).

## Client groups

`FastestMCP.ClientGroup.list_tools/2` lists the tools of every member of a
group, following each member's pages, and returns one list, with each tool's
name prefixed by its member's alias. A group has no cursors: each call lists
every member again, and refreshes the tools that
`FastestMCP.ClientGroup.call_tool/4` can route to. A group lists only tools;
for a member's prompts and resources, take its client with
`FastestMCP.ClientGroup.client/2` and list them as in the previous section.
[Client groups](client.md#client-groups) covers groups in full.

## Details

### Cursors on the wire

A FastestMCP server sends pages of 100 items, in name order, and includes
`nextCursor` in a result only when another page follows. A client cannot
choose the page size: the server ignores a `pageSize` field.

A wire cursor is an opaque string of at most 4 KiB, signed with the server's
`signing_secret:` runtime option, or without one with a random key that the
server creates when it starts. It records the last item of its page, by name
and version, so the next page starts after that item even when components are
added or removed between the two requests.

A cursor continues one listing only. It is bound to the list method, the
caller's identity, the `2025-11-25` session, and the visibility rules. A server
rejects a cursor from another method, caller, or session, a modified cursor,
and a cursor signed with another key, with the JSON-RPC error `-32602` and the
message `invalid cursor`. Without a `signing_secret:`, that includes every
cursor the server issued before a restart, and every cursor of another node.
`FastestMCP.Client` returns that error as `:bad_request`. Start the listing
again from the first page.

When you run several nodes, give them the same `signing_secret:`, and any node
continues a listing; see
[Running several nodes](production.md#running-several-nodes).

### Local cursors

The cursors of in-process lists are positions in the list. They are not signed,
so keep them inside your application. A component added or removed between two
calls shifts the positions, so the next page can repeat or skip an item.

### Providers

A provider can serve pages from its own source, such as a database, by
implementing `c:FastestMCP.Provider.list_component_page/5`. Otherwise, and for
every provider with transforms or on a server with server transforms,
FastestMCP lists the provider's components in full and then takes the page; see
[Custom providers](providers-and-mounting.md#custom-providers).

## See also

- [Client](client.md#listing-and-paging): listing and paging from a connected
  client
- [Providers and Mounting](providers-and-mounting.md): providers that page at
  the source
- [Versioning and Visibility](versioning-and-visibility.md): what a caller can
  see in a list
