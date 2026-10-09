defmodule FastestMCP.ProviderExtensionsTest do
  use FastestMCP.Case, async: true
  alias FastestMCP.{Client, Provider, ServerExtension}

  defmodule BundledProvider do
    use FastestMCP.Provider
    defstruct extensions: []
    def required_extensions(provider), do: provider.extensions
    def list_components(_, _, _), do: []
  end

  test "nested and transformed bundles run once per root and preserve child lifespan isolation" do
    parent = self()
    id = "com.example/bundled"

    extension =
      ServerExtension.new(id,
        auto_register: true,
        lifespan: fn server ->
          send(parent, {:entered, server.name})
          {%{"root" => server.name}, fn -> send(parent, {:cleaned, server.name}) end}
        end,
        tool_interceptor: fn operation, next ->
          send(parent, {:intercepted, operation.context.server_name})
          next.(operation)
        end,
        methods: [{"bundled/state", fn _, ctx -> ctx.lifespan_context[id] end}]
      )

    provider =
      %BundledProvider{extensions: [extension]}
      |> Provider.add_transform(FastestMCP.ProviderTransforms.Namespace.new("bundle"))

    child =
      FastestMCP.server("bundle-child",
        active_extensions: [extension],
        lifespan: fn _ -> %{"child" => true} end
      )
      |> FastestMCP.add_provider(provider)
      |> FastestMCP.add_tool("state", fn _, ctx -> ctx.lifespan_context end)

    middle = FastestMCP.server("bundle-middle") |> FastestMCP.mount(child, namespace: "inner")

    for name <- [unique_name("bundle-root-one"), unique_name("bundle-root-two")] do
      server =
        FastestMCP.server(name, lifespan: fn _ -> %{"private_parent" => true} end)
        |> FastestMCP.add_extension(
          ServerExtension.new("com.example/private", lifespan: fn _ -> %{"private" => true} end)
        )
        |> FastestMCP.mount(middle, namespace: "outer")

      start_server!(server)
      assert_receive {:entered, ^name}
      refute_receive {:entered, ^name}
      client = Client.connect!({:in_process, name}, extensions: %{id => %{}})

      try do
        assert %{structured_content: state} = Client.call_tool!(client, "outer_inner_state")
        assert state == %{"child" => true, id => %{"root" => name}}
        assert_receive {:intercepted, ^name}
        refute_receive {:intercepted, ^name}

        assert %{"root" => ^name} =
                 Client.request!(client, "bundled/state", %{}) |> Map.take(["root"])
      after
        if Client.connected?(client), do: Client.disconnect!(client)
        FastestMCP.stop_server(name)
      end

      assert_receive {:cleaned, ^name}
      refute_receive {:cleaned, ^name}
    end

    assert child.active_extensions == [ServerExtension.normalize!(extension)]
  end

  test "conflicting bundles require an explicit root definition independent of builder order" do
    id = "com.example/conflict"
    first = ServerExtension.new(id, auto_register: true, settings: %{version: 1})
    second = ServerExtension.new(id, auto_register: true, settings: %{version: 2})
    provider = %BundledProvider{extensions: [first, second]}

    server =
      FastestMCP.server(unique_name("bundle-conflict")) |> FastestMCP.add_provider(provider)

    assert {:error, %ArgumentError{message: message}} = FastestMCP.start_server(server)
    assert message =~ "conflicting provider extension"

    for first? <- [true, false] do
      name = unique_name("bundle-explicit-#{first?}")
      root = FastestMCP.server(name)

      root =
        if first?,
          do: root |> FastestMCP.add_extension(second) |> FastestMCP.add_provider(provider),
          else: root |> FastestMCP.add_provider(provider) |> FastestMCP.add_extension(second)

      start_server!(root)
      assert {:ok, runtime} = FastestMCP.ServerRuntime.fetch(name)
      assert [%{settings: %{"version" => 2}}] = runtime.server.active_extensions
    end
  end

  test "failed bundled startup rolls back already entered lifespans" do
    parent = self()

    first =
      ServerExtension.new("com.example/entered",
        auto_register: true,
        lifespan: fn _ ->
          {%{}, fn -> send(parent, :rolled_back) end}
        end
      )

    broken =
      ServerExtension.new("com.example/broken",
        auto_register: true,
        lifespan: fn _ -> {:error, :broken} end
      )

    server =
      FastestMCP.server(unique_name("bundled-rollback"))
      |> FastestMCP.add_provider(%BundledProvider{extensions: [first, broken]})

    assert {:error, _} = FastestMCP.start_server(server)
    assert_receive :rolled_back
    refute_receive :rolled_back
    assert {:error, :not_found} = FastestMCP.ServerRuntime.fetch(server.name)
  end
end
