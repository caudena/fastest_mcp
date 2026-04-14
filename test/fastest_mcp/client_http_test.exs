defmodule FastestMCP.ClientHTTPTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Error
  alias FastestMCP.Interact
  alias FastestMCP.Protocol

  test "connected client initializes and works against a live streamable HTTP server" do
    test_pid = self()
    server_name = "client-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_tool("slow", fn _arguments, _ctx ->
        send(test_pid, :slow_tool_started)
        Process.sleep(200)
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "client-http-test", "version" => "1.0.0"},
        max_in_flight: 1
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert Client.connected?(client)
    assert Client.protocol_version(client) == Protocol.current_version()
    assert is_map(Client.initialize_result(client))
    assert is_map(Client.capabilities(client))

    assert [%{"name" => "echo"}, %{"name" => "slow"}] =
             client
             |> Client.list_tools()
             |> Map.fetch!(:items)
             |> Enum.sort_by(& &1["name"])

    assert %{"message" => "hi"} = Client.call_tool(client, "echo", %{"message" => "hi"})

    task = Task.async(fn -> Client.call_tool(client, "slow", %{}) end)

    assert_receive :slow_tool_started, 1_000

    error =
      assert_raise Error, fn ->
        Client.call_tool(client, "echo", %{"message" => "blocked"})
      end

    assert error.code == :overloaded
    assert %{"ok" => true} = Task.await(task, 1_000)
  end

  test "connected client lists and reads resources, templates, and prompts over HTTP" do
    server_name = "client-http-content-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("memo://welcome", fn _arguments, _ctx -> %{message: "hello"} end,
        tags: ["docs", "utility"],
        version: "2.0.0",
        task: true,
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx ->
          %{id: id, kind: "template"}
        end,
        tags: ["docs", "utility"],
        version: "2.0.0",
        task: true,
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      )
      |> FastestMCP.add_prompt("welcome", fn %{"name" => name}, _ctx ->
        [
          %{
            role: "user",
            content: %{type: "text", text: "Welcome #{name}"}
          }
        ]
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{items: [resource], next_cursor: nil} = Client.list_resources(client)

    assert resource == %{
             "uri" => "memo://welcome",
             "name" => "memo://welcome",
             "description" => "",
             "mimeType" => "application/json",
             "execution" => %{"taskSupport" => "optional"},
             "_meta" => %{
               "vendor" => %{"stable" => true},
               "fastestmcp" => %{
                 "hint" => "keep",
                 "tags" => ["docs", "utility"],
                 "version" => "2.0.0"
               }
             }
           }

    assert %{items: [template], next_cursor: nil} = Client.list_resource_templates(client)

    assert template == %{
             "uriTemplate" => "memo://users/{id}",
             "name" => "memo://users/{id}",
             "description" => "",
             "parameters" => %{},
             "mimeType" => "application/json",
             "execution" => %{"taskSupport" => "optional"},
             "_meta" => %{
               "vendor" => %{"stable" => true},
               "fastestmcp" => %{
                 "hint" => "keep",
                 "tags" => ["docs", "utility"],
                 "version" => "2.0.0"
               }
             }
           }

    assert %{items: [%{"name" => "welcome"}], next_cursor: nil} =
             Client.list_prompts(client)

    assert %{"message" => "hello"} = Client.read_resource(client, "memo://welcome")

    assert %{"messages" => [%{"content" => %{"text" => "Welcome Nate"}}]} =
             Client.render_prompt(client, "welcome", %{"name" => "Nate"})
  end

  test "connected client forwards version selectors for resource reads over HTTP" do
    server_name =
      "client-http-resource-version-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("memo://config", fn _arguments, _ctx -> %{version: "1.0.0"} end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource("memo://config", fn _arguments, _ctx -> %{version: "2.0.0"} end,
        version: "2.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> %{id: id, version: "1.0.0"} end,
        version: "1.0.0"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _ctx -> %{id: id, version: "2.0.0"} end,
        version: "2.0.0"
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    :ok =
      FastestMCP.disable_components(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"version" => "1.0.0"} = Client.read_resource(client, "memo://config")

    assert %{"id" => "42", "version" => "1.0.0"} =
             Client.read_resource(client, "memo://users/42")

    assert %{"version" => "1.0.0"} =
             Client.read_resource(client, "memo://config", version: "1.0.0")

    assert %{"id" => "42", "version" => "1.0.0"} =
             Client.read_resource(client, "memo://users/42", version: "1.0.0")

    assert_raise Error, ~r/disabled/, fn ->
      Client.read_resource(client, "memo://config", version: "2.0.0")
    end

    assert_raise Error, ~r/disabled/, fn ->
      Client.read_resource(client, "memo://users/42", version: "2.0.0")
    end
  end

  test "connected client uses pageSize for HTTP pagination helpers" do
    server_name =
      "client-http-pagination-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo_1", fn arguments, _ctx -> arguments end, task: true)
      |> FastestMCP.add_tool("echo_2", fn arguments, _ctx -> arguments end, task: true)
      |> FastestMCP.add_resource("memo://1", fn _arguments, _ctx -> %{id: 1} end)
      |> FastestMCP.add_resource("memo://2", fn _arguments, _ctx -> %{id: 2} end)
      |> FastestMCP.add_prompt("prompt_1", fn _arguments, _ctx -> "prompt-1" end)
      |> FastestMCP.add_prompt("prompt_2", fn _arguments, _ctx -> "prompt-2" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    task_a = Client.call_tool(client, "echo_1", %{"value" => 1}, task: true)
    task_b = Client.call_tool(client, "echo_2", %{"value" => 2}, task: true)

    assert %{"value" => 1} = RemoteTask.result(task_a)
    assert %{"value" => 2} = RemoteTask.result(task_b)

    assert %{items: [_one_tool], next_cursor: tool_cursor} =
             Client.list_tools(client, page_size: 1)

    assert is_binary(tool_cursor)

    assert %{items: [_one_prompt], next_cursor: prompt_cursor} =
             Client.list_prompts(client, page_size: 1)

    assert is_binary(prompt_cursor)

    assert %{items: [_one_resource], next_cursor: resource_cursor} =
             Client.list_resources(client, page_size: 1)

    assert is_binary(resource_cursor)

    assert %{items: [first_task], next_cursor: task_cursor} =
             Client.list_tasks(client, page_size: 1)

    assert is_binary(task_cursor)
    assert first_task["taskId"] in [task_a.task_id, task_b.task_id]

    assert %{items: [second_task], next_cursor: nil} =
             Client.list_tasks(client, page_size: 1, cursor: task_cursor)

    assert second_task["taskId"] in [task_a.task_id, task_b.task_id]
    refute second_task["taskId"] == first_task["taskId"]
  end

  test "connected client forwards log and progress notifications to handlers" do
    parent = self()

    server_name =
      "client-http-notifications-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("notify", fn _arguments, ctx ->
        Context.log(ctx, :info, "hello from server")
        Context.report_progress(ctx, 5, 10, "halfway")
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        log_handler: fn payload -> send(parent, {:log_notification, payload}) end,
        progress_handler: fn payload -> send(parent, {:progress_notification, payload}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"ok" => true} = Client.call_tool(client, "notify", %{}, progress_token: "token-1")

    assert_receive {:log_notification, %{"level" => "info", "data" => "hello from server"}}, 1_000

    assert_receive {:progress_notification,
                    %{
                      "progressToken" => "token-1",
                      "progress" => 5,
                      "total" => 10,
                      "message" => "halfway"
                    }},
                   1_000
  end

  test "connected client handles sampling and elicitation callbacks over HTTP" do
    test_pid = self()

    server_name =
      "client-http-callbacks-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sample", fn _arguments, ctx ->
        Context.sample(ctx, "Reply with sampled")
      end)
      |> FastestMCP.add_tool("ask_name", fn _arguments, ctx ->
        case Context.elicit(ctx, "What is your name?", :string) do
          %Accepted{data: name} -> %{name: name}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_handler_called, messages, params})
          assert is_list(messages)
          assert params["maxTokens"] == 100
          %{"content" => %{"text" => "sampled"}}
        end,
        elicitation_handler: fn message, params ->
          send(test_pid, {:elicitation_handler_called, message, params})
          assert message == "What is your name?"
          assert params["requestedSchema"] == %{"type" => "string"}
          {:accept, %{"value" => "Alice"}}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    sample_task = Task.async(fn -> Client.call_tool(client, "sample", %{}) end)
    assert_receive {:sampling_handler_called, _messages, _params}, 1_000
    assert %{"text" => "sampled"} = Task.await(sample_task, 6_000)

    elicitation_task = Task.async(fn -> Client.call_tool(client, "ask_name", %{}) end)
    assert_receive {:elicitation_handler_called, _message, _params}, 1_000
    assert %{"name" => "Alice"} = Task.await(elicitation_task, 6_000)
  end

  test "connected client reuses per-request auth for protected sampling and elicitation callbacks" do
    test_pid = self()

    server_name =
      "client-http-protected-callbacks-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "dev-token" => %{
            client_id: "local-client",
            scopes: ["tools:call"],
            principal: %{"sub" => "local-client"}
          }
        },
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("sample", fn _arguments, ctx ->
        Context.sample(ctx, "Reply with sampled")
      end)
      |> FastestMCP.add_tool("ask_name", fn _arguments, ctx ->
        case Context.elicit(ctx, "What is your name?", :string) do
          %Accepted{data: name} -> %{name: name}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        sampling_handler: fn messages, params ->
          send(test_pid, {:protected_sampling_handler_called, messages, params})
          %{"content" => %{"text" => "sampled"}}
        end,
        elicitation_handler: fn message, params ->
          send(test_pid, {:protected_elicitation_handler_called, message, params})
          {:accept, %{"value" => "Alice"}}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    unauthorized_error =
      assert_raise Error, fn ->
        Client.call_tool(client, "sample", %{})
      end

    assert unauthorized_error.code == :unauthorized

    sample_task =
      Task.async(fn ->
        Client.call_tool(client, "sample", %{}, access_token: "dev-token")
      end)

    assert_receive {:protected_sampling_handler_called, _messages, _params}, 1_000
    assert %{"text" => "sampled"} = Task.await(sample_task, 6_000)

    elicitation_task =
      Task.async(fn ->
        Client.call_tool(client, "ask_name", %{}, access_token: "dev-token")
      end)

    assert_receive {:protected_elicitation_handler_called, "What is your name?",
                    %{"requestedSchema" => %{"type" => "string"}}},
                   1_000

    assert %{"name" => "Alice"} = Task.await(elicitation_task, 6_000)
  end

  test "opening a session stream fails against stateless HTTP servers" do
    server_name =
      "client-http-stateless-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any, stateless_http: true},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp", session_stream: false)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    error =
      assert_raise Error, fn ->
        Client.open_session_stream(client)
      end

    assert error.code == :bad_request
    refute Client.session_stream_open?(client)
  end

  test "connected client manages protected task lifecycle over HTTP" do
    server_name = "client-http-tasks-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "dev-token" => %{
            client_id: "local-client",
            scopes: ["tools:call"],
            principal: %{"sub" => "local-client"}
          }
        },
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool(
        "confirm",
        fn _arguments, ctx ->
          case Interact.confirm(ctx, "Proceed?") do
            {:ok, true} -> %{approved: true}
            {:ok, false} -> %{approved: false}
            :declined -> %{status: "declined"}
            :cancelled -> %{status: "cancelled"}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp", access_token: "dev-token")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "confirm"} =
             task = Client.call_tool(client, "confirm", %{}, task: true)

    assert %{items: [%{"taskId" => ^task_id}], next_cursor: nil} = Client.list_tasks(client)
    assert %{"taskId" => ^task_id} = Client.fetch_task(client, task_id)
    assert %{"taskId" => ^task_id} = RemoteTask.fetch(task)
    assert %{"taskId" => ^task_id} = RemoteTask.status(task)

    assert wait_for_task_status(client, task_id, "input_required") == :ok

    assert %{"taskId" => ^task_id, "status" => "input_required"} =
             RemoteTask.wait(task, status: "input_required")

    assert %{"taskId" => ^task_id} =
             Client.send_task_input(client, task_id, :accept, %{"confirmed" => true})

    assert wait_for_task_status(client, task_id, "completed") == :ok
    assert %{"approved" => true} = RemoteTask.result(task)
    assert %{"approved" => true} = RemoteTask.result(task)
  end

  test "connected client receives task notifications over the session event stream" do
    parent = self()

    server_name =
      "client-http-session-stream-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _arguments, ctx ->
          send(parent, {:session_stream_task_started, ctx.session_id, self()})

          receive do
            :release -> %{done: true}
          after
            5_000 -> %{timed_out: true}
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:session_stream_notification, payload})
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert wait_for_session_stream(client) == :ok
    assert Client.session_stream_open?(client)

    session_id = Client.session_id(client)

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "wait"} =
             task = Client.call_tool(client, "wait", %{}, task: true)

    assert_receive {:session_stream_task_started, ^session_id, task_pid}, 1_000

    assert_receive {:session_stream_notification,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "working"}
                    }},
                   1_000

    send(task_pid, :release)

    assert_receive {:session_stream_notification,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   1_000

    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait(task)
    assert wait_for_task_status(client, task_id, "completed") == :ok
  end

  test "notification handler failures do not fail tool calls" do
    server_name =
      "client-http-notification-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("notify", fn _arguments, ctx ->
        Context.log(ctx, :info, "hello from server")
        Context.report_progress(ctx, 1, 1, "done")
        %{ok: true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        log_handler: fn _payload -> raise "boom" end,
        progress_handler: fn _payload -> raise "boom" end,
        notification_handler: fn _payload -> raise "boom" end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"ok" => true} = Client.call_tool(client, "notify", %{}, progress_token: "token-1")
    assert Client.connected?(client)
  end

  test "connected client can update auth and handlers after connect" do
    parent = self()

    server_name =
      "client-http-runtime-updates-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{
          "dev-token" => %{
            client_id: "local-client",
            scopes: ["tools:call"],
            principal: %{"sub" => "local-client"}
          }
        },
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("headers", fn _arguments, ctx ->
        Context.http_headers(ctx, include_all: true)
      end)
      |> FastestMCP.add_tool("notify", fn _arguments, ctx ->
        Context.log(ctx, :info, "runtime hello")
        Context.report_progress(ctx, 2, 3, "runtime progress")
        %{ok: true}
      end)
      |> FastestMCP.add_tool("sample", fn _arguments, ctx ->
        Context.sample(ctx, "Reply with runtime sampled")
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        auto_initialize: false
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    :ok = Client.set_auth_input(client, headers: [{"x-trace-id", "trace-123"}])
    Client.set_access_token(client, "dev-token")
    Client.set_log_handler(client, fn payload -> send(parent, {:runtime_log, payload}) end)

    Client.set_progress_handler(client, fn payload ->
      send(parent, {:runtime_progress, payload})
    end)

    Client.set_notification_handler(client, fn payload ->
      send(parent, {:runtime_notification, payload})
    end)

    Client.set_sampling_handler(client, fn messages, _params ->
      send(parent, {:runtime_sampling, messages})
      %{"text" => "runtime sampled"}
    end)

    assert is_map(Client.initialize(client))

    assert %{
             "authorization" => "Bearer dev-token",
             "x-trace-id" => "trace-123"
           } = Client.call_tool(client, "headers", %{})

    assert %{"ok" => true} = Client.call_tool(client, "notify", %{}, progress_token: "token-2")

    assert_receive {:runtime_log, %{"level" => "info", "data" => "runtime hello"}}, 1_000

    assert_receive {:runtime_progress,
                    %{
                      "progressToken" => "token-2",
                      "progress" => 2,
                      "total" => 3,
                      "message" => "runtime progress"
                    }},
                   1_000

    assert_receive {:runtime_notification, %{"method" => "notifications/message", "params" => _}},
                   1_000

    assert_receive {:runtime_notification,
                    %{"method" => "notifications/progress", "params" => _}},
                   1_000

    assert %{"text" => "runtime sampled"} = Client.call_tool(client, "sample", %{})

    assert_receive {:runtime_sampling,
                    [%{"content" => %{"text" => "Reply with runtime sampled"}}]},
                   1_000
  end

  defp wait_for_task_status(client, task_id, expected_status, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_task_status(client, task_id, expected_status, deadline)
  end

  defp wait_for_session_stream(client, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_session_stream(client, deadline)
  end

  defp do_wait_for_task_status(client, task_id, expected_status, deadline) do
    task = Client.fetch_task(client, task_id)

    cond do
      task["status"] == expected_status ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "timed out waiting for task #{inspect(task_id)} to reach #{inspect(expected_status)}"
        )

      true ->
        Process.sleep(10)
        do_wait_for_task_status(client, task_id, expected_status, deadline)
    end
  end

  defp do_wait_for_session_stream(client, deadline) do
    cond do
      Client.session_stream_open?(client) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the client session stream to open")

      true ->
        Process.sleep(10)
        do_wait_for_session_stream(client, deadline)
    end
  end
end
