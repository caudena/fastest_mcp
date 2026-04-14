# Dynamic Component Manager

Every running server gets an internal `FastestMCP.ComponentManager`.

It lets you add, remove, enable, and disable components through normal OTP
calls while keeping list, call, read, and prompt resolution consistent with the
live runtime state.

## Adding and Removing Components

```elixir
manager = FastestMCP.component_manager(MyApp.MCPServer)

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool(
    manager,
    "dynamic.echo",
    fn %{"value" => value}, _ctx -> %{value: value} end
  )

FastestMCP.list_tools(MyApp.MCPServer)
FastestMCP.call_tool(MyApp.MCPServer, "dynamic.echo", %{"value" => "hi"})

FastestMCP.ComponentManager.disable_tool(manager, "dynamic.echo")
FastestMCP.ComponentManager.enable_tool(manager, "dynamic.echo")
FastestMCP.ComponentManager.remove_tool(manager, "dynamic.echo")
```

The same pattern exists for resources, resource templates, and prompts.

## Why This Shape

Runtime mutation belongs inside the supervised runtime. The component manager
keeps the state transition local to the server process tree instead of splitting
authority between the runtime and an external management API.
