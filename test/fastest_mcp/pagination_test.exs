defmodule FastestMCP.PaginationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Error
  alias FastestMCP.Pagination
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  defmodule CountingPageProvider do
    defstruct [:pid, :tools]

    def list_components(%__MODULE__{pid: pid, tools: tools}, :tool, _operation) do
      send(pid, :unbounded_list_called)
      Tuple.to_list(tools)
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def list_component_page(
          %__MODULE__{pid: pid, tools: tools},
          :tool,
          after_key,
          limit,
          _operation
        ) do
      first_index = first_tool_index(after_key)
      last_index = min(tuple_size(tools), first_index + limit - 1)

      items =
        if first_index <= last_index do
          Enum.map(first_index..last_index, &elem(tools, &1 - 1))
        else
          []
        end

      next_after =
        if last_index < tuple_size(tools) and items != [] do
          items |> List.last() |> Pagination.default_key()
        end

      send(pid, {:bounded_page, after_key, limit, length(items)})
      {:ok, %{items: items, next_after: next_after}}
    end

    def list_component_page(%__MODULE__{}, _component_type, _after_key, _limit, _operation) do
      {:ok, %{items: [], next_after: nil}}
    end

    defp first_tool_index(nil), do: 1

    defp first_tool_index(["tool_" <> suffix, _version]) do
      String.to_integer(suffix) + 1
    end
  end

  defmodule FamilyPageProvider do
    defstruct [:pid, components: %{}]

    def list_components(%__MODULE__{pid: pid, components: components}, component_type, _operation) do
      send(pid, {:unbounded_family_list, component_type})
      Map.get(components, component_type, [])
    end

    def list_component_page(
          %__MODULE__{pid: pid, components: components},
          component_type,
          after_key,
          limit,
          _operation
        ) do
      send(pid, {:family_page, component_type, after_key, limit})

      {:ok,
       components
       |> Map.get(component_type, [])
       |> Pagination.source_page(after_key, limit)}
    end
  end

  test "cursor encoding and decoding roundtrip" do
    cursor = Pagination.encode_cursor(12)
    assert {:ok, 12} = Pagination.decode_cursor(cursor)
  end

  test "invalid cursor raises through pagination helper" do
    assert_raise Error, ~r/invalid cursor/, fn ->
      Pagination.paginate([1, 2, 3], "bad-cursor", 2)
    end
  end

  test "page_size must be positive" do
    assert_raise Error, ~r/page_size must be a positive integer/, fn ->
      Pagination.paginate([1, 2, 3], nil, 0)
    end
  end

  test "wire cursors are cursor-only keyset continuations bound to their scope" do
    secret = :crypto.strong_rand_bytes(32)
    items = Enum.map(1..205, &%{name: "item-#{String.pad_leading(to_string(&1), 3, "0")}"})

    first = Pagination.wire_page(items, secret: secret, scope: "tools/list")
    assert length(first.items) == 100
    assert is_binary(first.next_cursor)

    second =
      Pagination.wire_page(items,
        secret: secret,
        scope: "tools/list",
        cursor: first.next_cursor
      )

    assert length(second.items) == 100
    assert hd(second.items).name == "item-101"

    assert_raise Error, ~r/invalid cursor/, fn ->
      Pagination.wire_page(items,
        secret: secret,
        scope: "prompts/list",
        cursor: first.next_cursor
      )
    end
  end

  test "wire cursors reject tampering and caller-fingerprint reuse" do
    secret = :crypto.strong_rand_bytes(32)
    items = Enum.map(1..101, &%{name: "item-#{&1}"})

    first =
      Pagination.wire_page(items,
        secret: secret,
        scope: "tools/list",
        fingerprint: "principal-a"
      )

    assert_raise Error, ~r/invalid cursor/, fn ->
      Pagination.wire_page(items,
        secret: secret,
        scope: "tools/list",
        fingerprint: "principal-b",
        cursor: first.next_cursor
      )
    end

    [body, signature] = String.split(first.next_cursor, ".", parts: 2)
    replacement = if String.starts_with?(signature, "A"), do: "B", else: "A"
    tampered = body <> "." <> replacement <> String.slice(signature, 1..-1//1)

    assert_raise Error, ~r/invalid cursor/, fn ->
      Pagination.wire_page(items,
        secret: secret,
        scope: "tools/list",
        fingerprint: "principal-a",
        cursor: tampered
      )
    end
  end

  test "list APIs support explicit pagination without changing the default return shape" do
    server_name = "pagination-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      Enum.reduce(1..5, FastestMCP.server(server_name), fn index, acc ->
        acc
        |> FastestMCP.add_tool("tool_#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_resource("data://resource/#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_prompt("prompt_#{index}", fn _args, _ctx -> "prompt-#{index}" end)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 5 = length(FastestMCP.list_tools(server_name))

    %{items: tools_page_1, next_cursor: tools_cursor} =
      FastestMCP.list_tools(server_name, page_size: 2)

    %{items: tools_page_2, next_cursor: nil} =
      FastestMCP.list_tools(server_name, page_size: 3, cursor: Pagination.encode_cursor(2))

    assert Enum.map(tools_page_1, & &1.name) == ["tool_1", "tool_2"]
    assert is_binary(tools_cursor)
    assert Enum.map(tools_page_2, & &1.name) == ["tool_3", "tool_4", "tool_5"]

    %{items: resources_page, next_cursor: resources_cursor} =
      FastestMCP.list_resources(server_name, page_size: 2)

    %{items: prompts_page, next_cursor: prompts_cursor} =
      FastestMCP.list_prompts(server_name, page_size: 2)

    assert Enum.map(resources_page, & &1.uri) == ["data://resource/1", "data://resource/2"]
    assert Enum.map(prompts_page, & &1.name) == ["prompt_1", "prompt_2"]
    assert is_binary(resources_cursor)
    assert is_binary(prompts_cursor)
  end

  test "transport list methods use a server-owned page size and method-bound cursors" do
    server_name = "pagination-engine-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      Enum.reduce(1..105, FastestMCP.server(server_name), fn index, acc ->
        suffix = String.pad_leading(to_string(index), 3, "0")

        acc
        |> FastestMCP.add_tool("tool_#{suffix}", fn _args, _ctx -> index end)
        |> FastestMCP.add_resource("data://resource/#{suffix}", fn _args, _ctx -> index end)
        |> FastestMCP.add_resource_template(
          "data://template/#{suffix}/{id}",
          fn arguments, _ctx -> arguments end
        )
        |> FastestMCP.add_prompt("prompt_#{suffix}", fn _args, _ctx -> "prompt-#{index}" end)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    principal_a = %AuthResult{principal: "principal-a", auth: %{tenant: "a"}}

    first_tools =
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: principal_a,
        payload: %{"pageSize" => 2}
      })

    assert length(first_tools.tools) == 100
    assert hd(first_tools.tools)["name"] == "tool_001"
    assert is_binary(first_tools.nextCursor)

    second_tools =
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: principal_a,
        payload: %{"cursor" => first_tools.nextCursor}
      })

    assert Enum.map(second_tools.tools, & &1["name"]) ==
             Enum.map(101..105, &"tool_#{&1}")

    refute Map.has_key?(second_tools, :nextCursor)

    assert_raise Error, ~r/invalid cursor/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: %AuthResult{principal: "principal-b", auth: %{tenant: "b"}},
        payload: %{"cursor" => first_tools.nextCursor}
      })
    end

    assert_raise Error, ~r/invalid cursor/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "prompts/list",
        transport: :stdio,
        auth_result: principal_a,
        payload: %{"cursor" => first_tools.nextCursor}
      })
    end

    resources =
      Engine.dispatch!(server_name, %Request{
        method: "resources/list",
        transport: :stdio,
        payload: %{"pageSize" => 1}
      })

    templates =
      Engine.dispatch!(server_name, %Request{
        method: "resources/templates/list",
        transport: :stdio,
        payload: %{"pageSize" => 1}
      })

    prompts =
      Engine.dispatch!(server_name, %Request{
        method: "prompts/list",
        transport: :stdio,
        payload: %{"pageSize" => 1}
      })

    assert length(resources.resources) == 100
    assert length(templates.resourceTemplates) == 100
    assert length(prompts.prompts) == 100
    assert is_binary(resources.nextCursor)
    assert is_binary(templates.nextCursor)
    assert is_binary(prompts.nextCursor)
  end

  test "wire pagination delegates bounded keyset pages to providers" do
    server_name = "provider-page-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    tools =
      1..205
      |> Enum.map(fn index ->
        suffix = String.pad_leading(to_string(index), 3, "0")

        ComponentCompiler.compile(
          :tool,
          "counting-page-provider",
          "tool_#{suffix}",
          fn _arguments, _context -> index end,
          auth: fn _context ->
            send(test_pid, {:authorized, index})
            true
          end
        )
      end)
      |> List.to_tuple()

    server =
      server_name
      |> FastestMCP.server()
      |> FastestMCP.add_provider(%CountingPageProvider{pid: self(), tools: tools})

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    principal = %AuthResult{principal: "principal-a", auth: %{tenant: "a"}}

    first =
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: principal,
        payload: %{"pageSize" => 1}
      })

    assert length(first.tools) == 100
    assert hd(first.tools)["name"] == "tool_001"
    assert List.last(first.tools)["name"] == "tool_100"
    assert is_binary(first.nextCursor)
    assert_receive {:bounded_page, nil, 101, 101}
    refute_receive :unbounded_list_called, 20

    Enum.each(1..101, fn index ->
      assert_receive {:authorized, ^index}
    end)

    refute_receive {:authorized, _index}, 20

    second =
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: principal,
        payload: %{"cursor" => first.nextCursor}
      })

    assert length(second.tools) == 100
    assert hd(second.tools)["name"] == "tool_101"
    assert List.last(second.tools)["name"] == "tool_200"
    assert is_binary(second.nextCursor)
    assert_receive {:bounded_page, ["tool_100", ""], 101, 101}
    refute_receive :unbounded_list_called, 20

    Enum.each(101..201, fn index ->
      assert_receive {:authorized, ^index}
    end)

    refute_receive {:authorized, _index}, 20

    assert_raise Error, ~r/invalid cursor/, fn ->
      Engine.dispatch!(
        server_name,
        %Request{
          method: "tools/list",
          transport: :stdio,
          auth_result: principal,
          payload: %{"cursor" => first.nextCursor}
        },
        audience: :human
      )
    end

    refute_receive {:bounded_page, _after_key, _limit, _count}, 20

    :ok = FastestMCP.disable_components(server_name, names: ["tool_150"])

    assert_raise Error, ~r/invalid cursor/, fn ->
      Engine.dispatch!(server_name, %Request{
        method: "tools/list",
        transport: :stdio,
        auth_result: principal,
        payload: %{"cursor" => first.nextCursor}
      })
    end

    refute_receive {:bounded_page, _after_key, _limit, _count}, 20
  end

  test "every wire component list family uses the provider page callback" do
    server_name = "provider-page-families-#{System.unique_integer([:positive])}"

    components = %{
      tool: [
        ComponentCompiler.compile(
          :tool,
          "family-page-provider",
          "tool",
          fn _arguments, _context -> :ok end,
          []
        )
      ],
      resource: [
        ComponentCompiler.compile(
          :resource,
          "family-page-provider",
          "data://resource",
          fn _arguments, _context -> "resource" end,
          []
        )
      ],
      resource_template: [
        ComponentCompiler.compile(
          :resource_template,
          "family-page-provider",
          "data://resources/{id}",
          fn arguments, _context -> arguments end,
          []
        )
      ],
      prompt: [
        ComponentCompiler.compile(
          :prompt,
          "family-page-provider",
          "prompt",
          fn _arguments, _context -> "prompt" end,
          []
        )
      ]
    }

    server =
      server_name
      |> FastestMCP.server()
      |> FastestMCP.add_provider(%FamilyPageProvider{pid: self(), components: components})

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    requests = [
      {:tool, "tools/list", :tools},
      {:resource, "resources/list", :resources},
      {:resource_template, "resources/templates/list", :resourceTemplates},
      {:prompt, "prompts/list", :prompts}
    ]

    Enum.each(requests, fn {component_type, method, result_key} ->
      result =
        Engine.dispatch!(server_name, %Request{
          method: method,
          transport: :stdio,
          payload: %{}
        })

      assert [_item] = Map.fetch!(result, result_key)
      assert_receive {:family_page, ^component_type, nil, 101}
      refute_receive {:unbounded_family_list, ^component_type}, 20
    end)
  end
end
