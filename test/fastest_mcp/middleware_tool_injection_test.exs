defmodule FastestMCP.MiddlewareToolInjectionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Middleware

  test "generic tool injection adds tools to list_tools and handles tool calls" do
    server_name = "tool-injection-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("add", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => a + b} end)
      |> FastestMCP.add_middleware(
        Middleware.tool_injection([
          {"multiply", fn %{"a" => a, "b" => b}, _ctx -> %{"result" => a * b} end,
           [description: "Multiply two numbers."]}
        ])
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tool_names =
      server_name
      |> FastestMCP.list_tools()
      |> Enum.map(& &1.name)

    assert tool_names == ["multiply", "add"]

    assert %{"result" => 42} =
             FastestMCP.call_tool(server_name, "multiply", %{"a" => 7, "b" => 6})

    assert %{"result" => 9} = FastestMCP.call_tool(server_name, "add", %{"a" => 4, "b" => 5})
  end

  test "injected tools override base tools with the same name" do
    server_name = "tool-override-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"message" => message}, _ctx ->
        %{"message" => message}
      end)
      |> FastestMCP.add_middleware(
        Middleware.tool_injection([
          {"echo", fn %{"message" => message}, _ctx -> %{"message" => String.upcase(message)} end}
        ])
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"message" => "HELLO"} =
             FastestMCP.call_tool(server_name, "echo", %{"message" => "hello"})
  end

  test "prompt tools expose prompt listing and rendering through injected tools" do
    server_name = "prompt-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx ->
        [%{role: "user", content: "Hello #{name}"}]
      end)
      |> FastestMCP.add_middleware(Middleware.prompt_tools())

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"prompts" => prompts} = FastestMCP.call_tool(server_name, "list_prompts", %{})
    assert Enum.any?(prompts, &(&1.name == "greet"))

    assert %{
             "result" => %{
               messages: [%{role: "user", content: %{type: "text", text: "Hello Nate"}}]
             }
           } =
             FastestMCP.call_tool(server_name, "get_prompt", %{
               "name" => "greet",
               "arguments" => %{"name" => "Nate"}
             })
  end

  test "resource tools expose resource listing, templates, and reads through injected tools" do
    server_name = "resource-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("config://app", fn _arguments, _ctx ->
        %{"theme" => "sunrise"}
      end)
      |> FastestMCP.add_resource_template("docs://{slug}", fn %{"slug" => slug}, _ctx ->
        %{"slug" => slug}
      end)
      |> FastestMCP.add_middleware(Middleware.resource_tools())

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"resources" => resources, "resource_templates" => templates} =
             FastestMCP.call_tool(server_name, "list_resources", %{})

    assert Enum.any?(resources, &(&1.uri == "config://app"))
    assert Enum.any?(templates, &(&1.uri_template == "docs://{slug}"))

    assert %{"result" => %{"theme" => "sunrise"}} =
             FastestMCP.call_tool(server_name, "read_resource", %{"uri" => "config://app"})
  end

  test "multiple tool injection middlewares can be stacked" do
    server_name = "tool-stack-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
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

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert ["power", "modulo", "subtract"] ==
             server_name
             |> FastestMCP.list_tools()
             |> Enum.map(& &1.name)

    assert %{"result" => 8} = FastestMCP.call_tool(server_name, "power", %{"a" => 2, "b" => 3})
    assert %{"result" => 1} = FastestMCP.call_tool(server_name, "modulo", %{"a" => 10, "b" => 3})
  end
end
