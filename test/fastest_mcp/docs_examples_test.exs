defmodule FastestMCP.DocsExamplesTest do
  use ExUnit.Case, async: false

  @moduletag :docs_examples

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolResult
  alias FastestMCP.ComponentManager
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Providers.ApplicationSessions
  alias FastestMCP.Providers.Proxy
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Resources.Text, as: ResourceText
  alias FastestMCP.ResourceSecurity
  alias FastestMCP.ServerExtension
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

    assert %{"resultType" => "complete", "structuredContent" => 42} =
             Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
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

          %{
            "role" => "assistant",
            "model" => "docs-test-model",
            "content" => %{"type" => "text", "text" => "short summary"}
          }
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{
             "resultType" => "complete",
             "structuredContent" => %{"text" => "short summary"}
           } = Client.call_tool(client, "summarize", %{})

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

    assert "local-client" ==
             DocsFixture.nested_fetch(whoami, [:structuredContent, :principal, :sub])

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

    assert error.code == :disabled
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
      FastestMCP.server(server_name)
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
        fn _args, _ctx -> %{"values" => ["alpha", "beta"]} end,
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "values" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["values"]
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

    assert 42 == FastestMCP.call_tool(server_name, "calculate_sum", %{"a" => 20, "b" => 22})

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
             "resultType" => "complete",
             "structuredContent" => %{"values" => ["alpha", "beta"]}
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

    assert %{
             "resultType" => "complete",
             "contents" => [
               %{
                 "uri" => "config://release",
                 "mimeType" => "application/json",
                 "text" => encoded_release
               }
             ]
           } = Client.read_resource(client, "config://release")

    assert %{"name" => "fastest_mcp", "version" => "0.1.0"} = JSON.decode!(encoded_release)
  end

  test "application sessions, authorization, extensions, and modern client examples work" do
    extension_id = "com.example/docs"

    authorization_context = %FastestMCP.Authorization.Context{
      authenticated: true,
      verified_scopes: ["reports:read"],
      capabilities: ["batch"]
    }

    assert FastestMCP.Authorization.run_checks(
             [
               FastestMCP.Authorization.require_scopes("reports:read"),
               FastestMCP.Authorization.require_capabilities("batch")
             ],
             authorization_context
           )

    assert %ResourceSecurity{} = ResourceSecurity.new()

    extension =
      ServerExtension.new(extension_id,
        methods: [
          ServerExtension.method(
            "docs/echo",
            fn params, _context -> %{"echo" => params["value"]} end,
            params_schema: %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => "string"}},
              "required" => ["value"]
            }
          )
        ]
      )

    test_pid = self()
    server_name = "docs-modern-apis-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name,
        application_sessions: [allow_anonymous: true],
        extensions: %{Extensions.tasks() => %{}},
        active_extensions: [extension]
      )
      |> FastestMCP.add_tool("application_session_round_trip", fn _arguments, context ->
        session = FastestMCP.ApplicationSession.create!(context)
        session_id = FastestMCP.ApplicationSession.id(session)
        session = FastestMCP.ApplicationSession.fetch!(context, session_id)
        :ok = FastestMCP.ApplicationSession.put(session, :value, "stored")
        {:ok, stored} = FastestMCP.ApplicationSession.get(session, :value)
        :ok = FastestMCP.ApplicationSession.delete(session, :value)
        {:ok, missing} = FastestMCP.ApplicationSession.get(session, :value, "missing")
        :ok = FastestMCP.ApplicationSession.terminate(session)
        %{"stored" => stored, "missing" => missing}
      end)
      |> FastestMCP.add_tool("report_progress", fn _arguments, context ->
        :ok = Context.report_progress(context, 1, 1, "done")
        %{"ok" => true}
      end)
      |> FastestMCP.add_tool(
        "task_echo",
        fn arguments, _context -> arguments end,
        task: [mode: :optional, poll_interval_ms: 20]
      )
      |> FastestMCP.add_resource("docs://status", fn _arguments, _context -> "ready" end)
      |> FastestMCP.add_resource_template(
        "safe://{+path}",
        fn %{"path" => path}, _context -> %{"path" => path} end
      )
      |> FastestMCP.add_prompt("docs_prompt", fn _arguments, _context ->
        %{
          messages: [
            %{role: "user", content: %{type: "text", text: "docs example"}}
          ]
        }
      end)
      |> FastestMCP.add_provider(ApplicationSessions.new())

    assert {:ok, _pid} = FastestMCP.start_server(server)
    bandit = start_supervised!(DocsFixture.bandit_child_spec(server_name))
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    endpoint = "http://127.0.0.1:#{port}/mcp"

    client =
      Client.connect!(endpoint,
        protocol_version: "2026-07-28",
        response_cache: [max_entries: 32, max_item_size: 100_000],
        extensions: %{
          Extensions.tasks() => %{},
          extension_id => %{}
        }
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Process.alive?(bandit), do: Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end)

    assert %{"path" => "folder/file.txt"} =
             FastestMCP.read_resource(server_name, "safe://folder/file.txt")

    error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "safe://../secret")
      end

    assert error.code == :not_found

    assert Enum.any?(Client.list_all_tools(client), &(&1["name"] == "task_echo"))
    assert [%{"name" => "docs_prompt"}] = Client.list_all_prompts(client)
    assert [%{"uri" => "docs://status"}] = Client.list_all_resources(client)
    assert [%{"uriTemplate" => "safe://{+path}"}] = Client.list_all_resource_templates(client)
    assert %{items: _tools} = Client.list_tools(client, cache: :bypass)

    assert %{"echo" => "active", "resultType" => "complete"} =
             Client.request(client, "docs/echo", %{"value" => "active"})

    assert %{
             "structuredContent" => %{"stored" => "stored", "missing" => "missing"}
           } = Client.call_tool(client, "application_session_round_trip", %{})

    assert %{"structuredContent" => %{"ok" => true}} =
             Client.call_tool(client, "report_progress", %{},
               progress_handler: fn params -> send(test_pid, {:docs_progress, params}) end
             )

    assert_receive {:docs_progress, %{"progress" => 1, "total" => 1, "message" => "done"}},
                   1_000

    task = Client.call_tool_task(client, "task_echo", %{"value" => "task"})
    assert %RemoteTask{} = task

    assert %{"value" => "task"} = RemoteTask.result(task, timeout_ms: 2_000)

    assert %ToolResult{
             structured_content: %{"value" => "stable"},
             structured_content_present?: true
           } =
             Client.call_tool_result(client, "task_echo", %{"value" => "stable"},
               task_timeout_ms: 2_000
             )

    assert %Proxy{protocol_version: :mirror, target_type: :http} = Proxy.new(endpoint)

    search_server_name =
      "docs-tool-search-" <> Integer.to_string(System.unique_integer([:positive]))

    search_server =
      FastestMCP.server(search_server_name)
      |> FastestMCP.add_tool(
        "deploy_status",
        fn arguments, _context -> %{"target" => arguments["target"]} end,
        description: "Deploy status for an environment",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "target" => %{
              "type" => "string",
              "description" => "Deployment region or environment"
            }
          }
        }
      )
      |> FastestMCP.add_tool(
        "release_report",
        fn _arguments, _context -> %{"report" => true} end,
        title: "Deploy release report"
      )
      |> FastestMCP.enable_tool_search(
        pinned: ["deploy_status"],
        max_results: 2,
        max_scan: 8
      )

    assert {:ok, _pid} = FastestMCP.start_server(search_server)

    client_name = {:global, {__MODULE__, search_server_name}}
    client_id = {:docs_supervised_client, search_server_name}

    _pid =
      start_supervised!(
        {Client,
         target: {:in_process, search_server_name},
         name: client_name,
         id: client_id,
         protocol_version: "2026-07-28"}
      )

    on_exit(fn -> FastestMCP.stop_server(search_server_name) end)

    assert :ok = Client.await_ready(client_name, 1_000)

    assert %{
             "structuredContent" => %{
               "tools" => [
                 %{"name" => "deploy_status"},
                 %{"name" => "release_report"}
               ],
               "truncated" => false
             }
           } = Client.call_tool(client_name, "search_tools", %{"query" => "deploy"})

    assert %{
             "structuredContent" => %{
               "tools" => [%{"name" => "deploy_status"}],
               "truncated" => false
             }
           } = Client.call_tool(client_name, "search_tools", %{"query" => "region"})

    assert %{"structuredContent" => %{"target" => "production"}} =
             Client.call_tool(client_name, "call_tool", %{
               "name" => "deploy_status",
               "arguments" => %{"target" => "production"}
             })

    assert :ok = stop_supervised(client_id)
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
