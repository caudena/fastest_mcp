defmodule FastestMCP.MiddlewareToolInjectionTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Authorization
  alias FastestMCP.Error
  alias FastestMCP.Middleware

  test "generic tool injection adds tools to list_tools and handles tool calls" do
    server_name = "tool-injection-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("add", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => a + b} end)
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"multiply", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => a * b} end,
         [description: "Multiply two numbers."]}
      ])
    )
    |> start_server!()

    tool_names =
      server_name
      |> FastestMCP.list_tools!()
      |> Enum.map(& &1.name)

    assert tool_names == ["multiply", "add"]

    assert %{"result" => 42} =
             FastestMCP.call_tool!(server_name, "multiply", %{"a" => 7, "b" => 6})

    assert %{"result" => 9} = FastestMCP.call_tool!(server_name, "add", %{"a" => 4, "b" => 5})
  end

  test "injected tools override base tools with the same name" do
    server_name = "tool-override-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"message" => message}, _ctx ->
      %{"message" => message}
    end)
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"echo", fn %{"message" => message}, _ctx -> %{"message" => String.upcase(message)} end}
      ])
    )
    |> start_server!()

    assert ["echo"] ==
             server_name
             |> FastestMCP.list_tools!()
             |> Enum.map(& &1.name)

    assert %{"message" => "HELLO"} =
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "hello"})
  end

  test "duplicate injected identities keep one list entry and execute the replacement" do
    server_name =
      "tool-injection-duplicate-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"echo", fn _arguments, _context -> %{"source" => "first"} end},
        {"other", fn _arguments, _context -> %{"source" => "other"} end},
        {"echo", fn _arguments, _context -> %{"source" => "replacement"} end}
      ])
    )
    |> start_server!()

    assert ["echo", "other"] ==
             server_name
             |> FastestMCP.list_tools!()
             |> Enum.map(& &1.name)

    assert %{"source" => "replacement"} ==
             FastestMCP.call_tool!(server_name, "echo", %{})
  end

  test "filtered injected tools fall back to a visible base tool with the same identity" do
    server_name =
      "tool-injection-filtered-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn _arguments, _context -> %{"source" => "base"} end)
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"echo", fn _arguments, _context -> %{"source" => "injected"} end, [enabled: false]}
      ])
    )
    |> start_server!()

    assert [%{name: "echo"}] = FastestMCP.list_tools!(server_name)
    assert %{"source" => "base"} = FastestMCP.call_tool!(server_name, "echo", %{})
  end

  test "injected tools use server transforms and component authorization exactly once" do
    server_name =
      "tool-injection-policy-" <> Integer.to_string(System.unique_integer([:positive]))

    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_transform(fn component, operation ->
        send(test_pid, {:injected_transform, component.name, operation.method})

        if component.name == "visible" do
          %{component | description: "transformed"}
        else
          component
        end
      end)
      |> FastestMCP.add_middleware(
        Middleware.tool_injection([
          {"visible", fn _arguments, _context -> "visible" end},
          {"secret", fn _arguments, _context -> "secret" end, [auth: fn _ctx -> false end]}
        ])
      )

    start_server!(server)

    assert [%{name: "visible", description: "transformed"}] =
             FastestMCP.list_tools!(server_name)

    assert_receive {:injected_transform, "visible", "tools/list"}
    assert_receive {:injected_transform, "secret", "tools/list"}
    refute_receive {:injected_transform, _name, "tools/list"}, 20

    assert "visible" = FastestMCP.call_tool!(server_name, "visible", %{})
    assert_receive {:injected_transform, "visible", "tools/call"}
    refute_receive {:injected_transform, "visible", "tools/call"}, 20

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_name, "secret", %{})
      end

    assert error.code == :forbidden
    assert_receive {:injected_transform, "secret", "tools/call"}
    refute_receive {:injected_transform, "secret", "tools/call"}, 20
  end

  test "prompt tools expose prompt listing and rendering through injected tools" do
    server_name = "prompt-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx ->
      FastestMCP.Prompts.Result.new("Hello #{name}")
    end)
    |> FastestMCP.add_middleware(Middleware.prompt_tools())
    |> start_server!()

    # The prompts as prompts/list describes them to clients.
    assert %{"prompts" => [prompt]} = FastestMCP.call_tool!(server_name, "list_prompts", %{})

    assert %{"name" => "greet", "description" => "", "arguments" => [], "_meta" => %{}} =
             prompt

    refute Enum.any?(["key", "enabled", "task", "tags"], &Map.has_key?(prompt, &1))

    assert %{
             "result" => %{
               messages: [%{role: "user", content: %{type: "text", text: "Hello Nate"}}]
             }
           } =
             FastestMCP.call_tool!(server_name, "get_prompt", %{
               "name" => "greet",
               "arguments" => %{"name" => "Nate"}
             })

    tools = Map.new(FastestMCP.list_tools!(server_name), &{&1.name, &1})

    assert %{
             "type" => "object",
             "properties" => %{"name" => %{"type" => "string"}, "arguments" => %{}},
             "required" => ["name"]
           } = tools["get_prompt"].input_schema

    assert {:error, %Error{code: :invalid_params}} =
             FastestMCP.call_tool(server_name, "get_prompt", %{"arguments" => %{}})
  end

  test "resource tools expose resource listing, templates, and reads through injected tools" do
    server_name = "resource-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_resource("config://app", fn _arguments, _ctx ->
      %{"theme" => "sunrise"}
    end)
    |> FastestMCP.add_resource_template("docs://{slug}", fn %{"slug" => slug}, _ctx ->
      %{"slug" => slug}
    end)
    |> FastestMCP.add_middleware(Middleware.resource_tools())
    |> start_server!()

    # The resources and templates as clients see them in their lists.
    assert %{"resources" => [resource], "resourceTemplates" => [template]} =
             FastestMCP.call_tool!(server_name, "list_resources", %{})

    assert %{"uri" => "config://app", "name" => "config://app"} = resource
    assert %{"uriTemplate" => "docs://{slug}", "name" => "docs://{slug}"} = template

    for descriptor <- [resource, template],
        key <- ["key", "enabled", "task", "tags", "uri_template"],
        do: refute(Map.has_key?(descriptor, key))

    assert %{"result" => %{"theme" => "sunrise"}} =
             FastestMCP.call_tool!(server_name, "read_resource", %{"uri" => "config://app"})

    tools = Map.new(FastestMCP.list_tools!(server_name), &{&1.name, &1})

    assert %{
             "type" => "object",
             "properties" => %{"uri" => %{"type" => "string"}},
             "required" => ["uri"]
           } = tools["read_resource"].input_schema

    assert {:error, %Error{code: :invalid_params}} =
             FastestMCP.call_tool(server_name, "read_resource", %{})
  end

  test "resource helper tools preserve verified authorization evidence in nested calls" do
    server_name =
      "resource-tools-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_resource("config://private", fn _arguments, _ctx -> "authorized" end,
      auth: Authorization.require_scopes("resources:read")
    )
    |> FastestMCP.add_middleware(Middleware.resource_tools())
    |> start_server!()

    assert %{"result" => "authorized"} ==
             FastestMCP.call_tool!(
               server_name,
               "read_resource",
               %{"uri" => "config://private"},
               authenticated: true,
               transport_authenticated: true,
               principal: {"https://issuer.example", "user-1"},
               verified_scopes: ["resources:read"]
             )
  end

  test "multiple tool injection middlewares can be stacked" do
    server_name = "tool-stack-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("subtract", fn %{"a" => a, "b" => b}, _ctx ->
      %{"result" => a - b}
    end)
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"power", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => round(:math.pow(a, b))} end}
      ])
    )
    |> FastestMCP.add_middleware(
      Middleware.tool_injection([
        {"modulo", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => rem(a, b)} end}
      ])
    )
    |> start_server!()

    assert ["power", "modulo", "subtract"] ==
             server_name
             |> FastestMCP.list_tools!()
             |> Enum.map(& &1.name)

    assert %{"result" => 8} = FastestMCP.call_tool!(server_name, "power", %{"a" => 2, "b" => 3})
    assert %{"result" => 1} = FastestMCP.call_tool!(server_name, "modulo", %{"a" => 10, "b" => 3})
  end
end
