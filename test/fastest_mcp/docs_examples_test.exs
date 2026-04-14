defmodule FastestMCP.DocsExamplesTest do
  use ExUnit.Case, async: false

  @moduletag :docs_examples

  alias FastestMCP.Client
  alias FastestMCP.ComponentManager
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Resources.Text, as: ResourceText
  alias FastestMCP.TestSupport.DocsFixture
  alias FastestMCP.TestSupport.DocsFixture.AuthServer
  alias FastestMCP.TestSupport.DocsFixture.InteractiveServer
  alias FastestMCP.TestSupport.DocsFixture.OnboardingServer

  test "onboarding guide examples work in process" do
    assert {:ok, _pid} = start_supervised(OnboardingServer)

    assert 42 == FastestMCP.call_tool(OnboardingServer, "sum", %{"a" => 20, "b" => 22})

    assert %{visits: 1, server: server_name} =
             FastestMCP.call_tool(OnboardingServer, "visit", %{}, session_id: "docs-session")

    assert server_name == to_string(OnboardingServer)

    assert %{visits: 2} =
             FastestMCP.call_tool(OnboardingServer, "visit", %{}, session_id: "docs-session")

    assert %{name: "fastest_mcp", version: "0.1.0"} ==
             FastestMCP.read_resource(OnboardingServer, "config://release")

    rendered = FastestMCP.render_prompt(OnboardingServer, "welcome", %{"name" => "Nate"})

    prompt_text =
      DocsFixture.nested_fetch(rendered, [:messages, 0, :content, :text]) ||
        DocsFixture.nested_fetch(rendered, [:messages, 0, :content])

    assert "Welcome Nate" == prompt_text
  end

  test "transport and client guide examples work over streamable http" do
    assert {:ok, _pid} = start_supervised(OnboardingServer)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(OnboardingServer))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "docs-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert ["sum", "visit"] ==
             client
             |> Client.list_tools()
             |> Map.fetch!(:items)
             |> Enum.map(& &1["name"])
             |> Enum.sort()

    assert %{items: [%{"name" => "welcome"}], next_cursor: nil} = Client.list_prompts(client)

    assert 42 == Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
  end

  test "sampling, interaction, and background task examples work against the docs fixture" do
    test_pid = self()

    assert {:ok, _pid} = start_supervised(InteractiveServer)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(InteractiveServer))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "docs-client", "version" => "1.0.0"},
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_handler_called, messages, params})
          %{"text" => "short summary"}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"text" => "short summary"} = Client.call_tool(client, "summarize", %{})

    assert_receive {:sampling_handler_called, _messages, %{"maxTokens" => 64}}, 1_000

    approval = FastestMCP.call_tool(InteractiveServer, "approve_release", %{}, task: true)
    :ok = DocsFixture.wait_for_input_required(InteractiveServer, approval.task_id)

    _ =
      FastestMCP.send_task_input(
        InteractiveServer,
        approval.task_id,
        :accept,
        %{"confirmed" => true}
      )

    assert %{approved: true} = FastestMCP.await_task(approval, 1_000)

    slow = FastestMCP.call_tool(InteractiveServer, "slow", %{}, task: true)
    assert :done == FastestMCP.await_task(slow, 1_000)
  end

  test "auth and component manager guide examples work" do
    assert {:ok, _pid} = start_supervised(AuthServer)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(AuthServer))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        access_token: "dev-token",
        client_info: %{"name" => "docs-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    whoami = Client.call_tool(client, "whoami", %{})
    assert "local-client" == DocsFixture.nested_fetch(whoami, [:principal, :sub])

    server_name =
      "docs-component-manager-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_name)
               |> FastestMCP.add_tool(
                 "beta.echo",
                 fn %{"value" => value}, _ctx -> %{value: value} end,
                 enabled: false
               )
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    manager = FastestMCP.component_manager(server_name)

    refute Enum.any?(FastestMCP.list_tools(server_name), &(&1.name == "beta.echo"))

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "beta.echo", %{"value" => "blocked"})
      end

    assert error.code == :disabled

    :ok = FastestMCP.enable_components(server_name, names: ["beta.echo"], components: [:tool])

    assert %{value: "live"} ==
             FastestMCP.call_tool(server_name, "beta.echo", %{"value" => "live"})

    assert {:ok, _tool} =
             ComponentManager.add_tool(
               manager,
               "dynamic.echo",
               fn %{"value" => value}, _ctx -> %{value: value} end
             )

    assert %{value: "hi"} == FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "hi"})

    assert {:ok, [_]} = ComponentManager.disable_tool(manager, "dynamic.echo")

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "dynamic.echo", %{"value" => "blocked"})
      end

    assert error.code == :not_found
    assert {:ok, _removed} = ComponentManager.remove_tool(manager, "dynamic.echo")
  end

  test "mounted provider examples work" do
    parent_name = "docs-mounted-parent-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-server")
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert %{"message" => "hi"} ==
             FastestMCP.call_tool(parent_name, "child_echo", %{"message" => "hi"})
  end

  test "tools guide examples work in process and over transport" do
    server_name = "docs-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, dereference_schemas: false)
      |> FastestMCP.add_tool(
        "calculate_sum",
        fn %{"a" => a, "b" => b}, _ctx -> a + b end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "integer"},
            "b" => %{"type" => "integer"}
          },
          "required" => ["a", "b"]
        }
      )
      |> FastestMCP.add_tool(
        "search_products",
        fn arguments, _ctx ->
          Map.take(arguments, ["query", "max_results", "sort_by", "category"])
        end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "max_results" => %{"type" => "integer"},
            "sort_by" => %{"type" => "string"},
            "category" => %{"type" => ["string", "null"]}
          },
          "required" => ["query"]
        }
      )
      |> FastestMCP.add_tool(
        "whoami",
        fn arguments, _ctx -> arguments end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "integer"}
          },
          "required" => ["value"]
        },
        inject: [session_id: fn ctx -> ctx.session_id end]
      )
      |> FastestMCP.add_tool(
        "ship_order",
        fn arguments, _ctx -> arguments end,
        input_schema: %{
          "$defs" => %{
            "address" => %{
              "type" => "object",
              "properties" => %{
                "city" => %{"type" => "string"}
              },
              "required" => ["city"]
            }
          },
          "type" => "object",
          "properties" => %{
            "shipping" => %{"$ref" => "#/$defs/address"}
          },
          "required" => ["shipping"]
        }
      )
      |> FastestMCP.add_tool(
        "list_values",
        fn _args, _ctx -> ["alpha", "beta"] end,
        output_schema: %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      )
      |> FastestMCP.add_tool("private_tool", fn _args, _ctx -> "private" end, tags: ["private"])
      |> FastestMCP.add_tool("explode", fn _args, _ctx ->
        raise Error, code: :bad_request, message: "boom"
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(server_name))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "docs-tools-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Process.alive?(bandit), do: Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end)

    assert 42 == FastestMCP.call_tool(server_name, "calculate_sum", %{"a" => "20", "b" => "22"})

    assert %{
             "query" => "coffee",
             "max_results" => 5,
             "sort_by" => "relevance",
             "category" => nil
           } =
             FastestMCP.call_tool(server_name, "search_products", %{
               "query" => "coffee",
               "max_results" => 5,
               "sort_by" => "relevance",
               "category" => nil
             })

    assert %{"value" => 7, "session_id" => "docs-session"} ==
             FastestMCP.call_tool(server_name, "whoami", %{"value" => 7},
               session_id: "docs-session"
             )

    shipped_tool = Enum.find(FastestMCP.list_tools(server_name), &(&1.name == "ship_order"))
    assert shipped_tool.input_schema["$defs"]["address"]["type"] == "object"
    assert shipped_tool.input_schema["properties"]["shipping"]["$ref"] == "#/$defs/address"

    assert %{
             "content" => [%{"type" => "text"}],
             "structuredContent" => %{"result" => ["alpha", "beta"]},
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
           } = Client.call_tool(client, "list_values", %{})

    :ok = FastestMCP.disable_components(server_name, tags: ["private"], components: [:tool])

    refute Enum.any?(FastestMCP.list_tools(server_name), &(&1.name == "private_tool"))

    assert_raise Error, ~r/boom/, fn ->
      FastestMCP.call_tool(server_name, "explode", %{})
    end
  end

  test "resources guide examples work in process and over transport" do
    server_name = "docs-resources-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("config://release", fn _arguments, _ctx ->
        %{name: "fastest_mcp", version: "0.1.0"}
      end)
      |> FastestMCP.add_resource_template(
        "users://{id}{?format}",
        fn %{"id" => id, "format" => format}, _ctx ->
          %{id: id, format: format || "summary"}
        end
      )
      |> FastestMCP.add_resource("reports://daily", fn _arguments, _ctx ->
        ResourceResult.new(
          [ResourceText.new("ready", meta: %{slot: "summary"})],
          meta: %{source: "docs"}
        )
      end)
      |> FastestMCP.add_resource("request://snapshot", fn _arguments, ctx ->
        request = Context.request_context(ctx)

        %{
          path: request.path,
          client_info: request.meta["clientInfo"]
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(server_name))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "docs-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Process.alive?(bandit), do: Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end)

    assert %{name: "fastest_mcp", version: "0.1.0"} ==
             FastestMCP.read_resource(server_name, "config://release")

    assert %{id: "42", format: "json"} ==
             FastestMCP.read_resource(server_name, "users://42?format=json")

    assert %{
             contents: [
               %{content: "ready", mime_type: "text/plain", meta: %{slot: "summary"}}
             ],
             meta: %{source: "docs"}
           } = FastestMCP.read_resource(server_name, "reports://daily")

    assert %{
             path: "/docs/resources",
             client_info: %{"name" => "docs-client", "version" => "1.0.0"}
           } =
             FastestMCP.read_resource(server_name, "request://snapshot",
               session_id: "docs-resources-session",
               request_metadata: %{
                 path: "/docs/resources",
                 clientInfo: %{"name" => "docs-client", "version" => "1.0.0"}
               }
             )

    assert %{items: resources, next_cursor: nil} = Client.list_resources(client)
    assert Enum.any?(resources, &(&1["uri"] == "config://release"))
    assert Enum.any?(resources, &(&1["uri"] == "reports://daily"))

    assert %{items: [%{"uriTemplate" => "users://{id}{?format}"}], next_cursor: nil} =
             Client.list_resource_templates(client)

    assert %{"name" => "fastest_mcp", "version" => "0.1.0"} =
             Client.read_resource(client, "config://release")
  end

  test "readme and guide links resolve and no compatibility sidecar references remain" do
    files = ["README.md" | Path.wildcard("docs/*.md")]

    Enum.each(files, fn file ->
      body = File.read!(file)
      refute String.contains?(body, "COMPATIBILITY.md")

      body
      |> then(&Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.reject(&skip_link?/1)
      |> Enum.each(fn link ->
        {target, _anchor} = split_anchor(link)
        expanded = Path.expand(target, Path.dirname(file))

        assert File.exists?(expanded),
               "#{file} points to missing local target #{inspect(link)}"
      end)
    end)
  end

  defp skip_link?(link) do
    String.starts_with?(link, ["#", "http://", "https://", "mailto:"])
  end

  defp split_anchor(link) do
    case String.split(link, "#", parts: 2) do
      [target, anchor] -> {target, anchor}
      [target] -> {target, nil}
    end
  end
end
