defmodule FastestMCP.ClientHTTPTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Error
  alias FastestMCP.Session

  defmodule NotFoundPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defmodule GatewayTimeoutPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 504, "upstream request timeout")
  end

  test "connected client initializes and works against a live streamable HTTP server" do
    test_pid = self()
    server_name = "client-http-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> FastestMCP.add_tool("slow", fn _arguments, _ctx ->
      send(test_pid, {:slow_tool_started, self()})

      receive do
        :release -> %{ok: true}
      end
    end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        client_info: %{"name" => "client-http-test", "version" => "1.0.0"},
        max_in_flight: 1
      )

    assert Client.connected?(client)

    assert %Client.Info{protocol_version: "2025-11-25", initialize_result: %{}, capabilities: %{}} =
             Client.info!(client)

    assert [%{"name" => "echo"}, %{"name" => "slow"}] =
             client
             |> Client.list_tools!()
             |> Map.fetch!(:items)
             |> Enum.sort_by(& &1["name"])

    assert %{structured_content: %{"message" => "hi"}} =
             Client.call_tool!(client, "echo", %{"message" => "hi"})

    task = Task.async(fn -> Client.call_tool!(client, "slow", %{}) end)

    assert_receive {:slow_tool_started, slow_tool}, 1_000

    error =
      assert_raise Error, fn ->
        Client.call_tool!(client, "echo", %{"message" => "blocked"})
      end

    assert error.code == :overloaded
    send(slow_tool, :release)
    assert %{structured_content: %{"ok" => true}} = Task.await(task, 1_000)
  end

  test "connected client lists and reads resources, templates, and prompts over HTTP" do
    server_name = "client-http-content-" <> Integer.to_string(System.unique_integer([:positive]))

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
      FastestMCP.Prompts.Result.new("Welcome #{name}")
    end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client = connect!(url, protocol_version: "2025-11-25")

    assert %{items: [resource], next_cursor: nil} = Client.list_resources!(client)

    assert resource == %{
             "uri" => "memo://welcome",
             "name" => "memo://welcome",
             "description" => "",
             "_meta" => %{
               "vendor" => %{"stable" => true},
               "fastestmcp" => %{
                 "hint" => "keep",
                 "tags" => ["docs", "utility"],
                 "version" => "2.0.0"
               }
             }
           }

    assert %{items: [template], next_cursor: nil} = Client.list_resource_templates!(client)

    assert template == %{
             "uriTemplate" => "memo://users/{id}",
             "name" => "memo://users/{id}",
             "description" => "",
             "_meta" => %{
               "vendor" => %{"stable" => true},
               "fastestmcp" => %{
                 "hint" => "keep",
                 "parameters" => %{},
                 "tags" => ["docs", "utility"],
                 "version" => "2.0.0"
               }
             }
           }

    assert %{items: [%{"name" => "welcome"}], next_cursor: nil} =
             Client.list_prompts!(client)

    assert %{"message" => "hello"} = read_json!(client, "memo://welcome")

    assert %{"messages" => [%{"content" => %{"text" => "Welcome Nate"}}]} =
             Client.render_prompt!(client, "welcome", %{"name" => "Nate"})
  end

  test "connected client forwards version selectors for resource reads over HTTP" do
    server_name =
      "client-http-resource-version-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    :ok =
      FastestMCP.disable_components!(server_name,
        version: %{eq: "2.0.0"},
        components: [:resource, :resource_template]
      )

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client = connect!(url, protocol_version: "2025-11-25")

    assert %{"version" => "1.0.0"} = read_json!(client, "memo://config")

    assert %{"id" => "42", "version" => "1.0.0"} = read_json!(client, "memo://users/42")

    assert %{"version" => "1.0.0"} = read_json!(client, "memo://config", version: "1.0.0")

    assert %{"id" => "42", "version" => "1.0.0"} =
             read_json!(client, "memo://users/42", version: "1.0.0")

    assert_raise Error, ~r{unknown resource "memo://config"}, fn ->
      Client.read_resource!(client, "memo://config", version: "2.0.0")
    end

    assert_raise Error, ~r{unknown resource "memo://users/42"}, fn ->
      Client.read_resource!(client, "memo://users/42", version: "2.0.0")
    end
  end

  test "connected client lists complete pages and rejects page size options" do
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

    start_server!(server)

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client = connect!(url, protocol_version: "2025-11-25")

    task_a = Client.call_tool_task!(client, "echo_1", %{"value" => 1}, task: true)
    task_b = Client.call_tool_task!(client, "echo_2", %{"value" => 2}, task: true)
    task_a_id = task_a.task_id
    task_b_id = task_b.task_id

    assert %{
             "structuredContent" => %{"value" => 1},
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_a_id}
             }
           } = RemoteTask.result!(task_a).raw

    assert %{
             "structuredContent" => %{"value" => 2},
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_b_id}
             }
           } = RemoteTask.result!(task_b).raw

    # The server owns the page size; the client has no page size option.
    assert_raise ArgumentError, ~r/unknown keys \[:page_size\]/, fn ->
      Client.list_tools(client, page_size: 1)
    end

    assert %{items: tools, next_cursor: nil} = Client.list_tools!(client)
    assert Enum.map(tools, & &1["name"]) == ["echo_1", "echo_2"]

    assert %{items: prompts, next_cursor: nil} = Client.list_prompts!(client)
    assert Enum.map(prompts, & &1["name"]) == ["prompt_1", "prompt_2"]

    assert %{items: resources, next_cursor: nil} = Client.list_resources!(client)
    assert Enum.map(resources, & &1["uri"]) == ["memo://1", "memo://2"]

    assert %{items: tasks, next_cursor: nil} = Client.list_tasks!(client)

    assert Enum.sort(Enum.map(tasks, & &1["taskId"])) ==
             Enum.sort([task_a.task_id, task_b.task_id])

    assert :ok = Client.disconnect!(client)
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

    start_server!(server)

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        log_handler: fn payload -> send(parent, {:log_notification, payload}) end,
        progress_handler: fn payload -> send(parent, {:progress_notification, payload}) end
      )

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "notify", %{}, progress_token: "token-1")

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

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("sample", fn _arguments, ctx ->
      Context.sample(ctx, "Reply with sampled")
    end)
    |> FastestMCP.add_tool("ask_name", fn _arguments, ctx ->
      case Context.elicit(ctx, "What is your name?", :string) do
        %Accepted{data: name} -> %{name: name}
      end
    end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_handler_called, messages, params})
          assert is_list(messages)
          assert params["maxTokens"] == 100
          sampling_result("sampled")
        end,
        elicitation_handler: fn message, params ->
          send(test_pid, {:elicitation_handler_called, message, params})
          assert message == "What is your name?"

          assert params["requestedSchema"] == %{
                   "type" => "object",
                   "properties" => %{"value" => %{"type" => "string"}},
                   "required" => ["value"]
                 }

          {:accept, %{"value" => "Alice"}}
        end
      )

    sample_task = Task.async(fn -> Client.call_tool!(client, "sample", %{}) end)
    assert_receive {:sampling_handler_called, _messages, _params}, 1_000

    assert %{structured_content: %{"content" => %{"text" => "sampled"}}} =
             Task.await(sample_task, 6_000)

    elicitation_task = Task.async(fn -> Client.call_tool!(client, "ask_name", %{}) end)
    assert_receive {:elicitation_handler_called, _message, _params}, 1_000
    assert %{structured_content: %{"name" => "Alice"}} = Task.await(elicitation_task, 6_000)
  end

  test "session stream handles standalone elicitation and returns primitive defaults" do
    parent = self()

    server_name =
      "client-http-standalone-elicitation-" <>
        Integer.to_string(System.unique_integer([:positive]))

    server = FastestMCP.server(server_name)

    start_server!(server)

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(url,
        protocol_version: "2025-11-25",
        session_stream: true,
        elicitation_handler: fn message, params ->
          send(parent, {:standalone_elicitation, message, params})
          {:accept, %{}}
        end
      )

    assert_eventually(fn -> Client.info!(client).session_stream_open? end)

    params = %{
      "message" => "Accept the defaults",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "default" => "John Doe"},
          "score" => %{"type" => "number", "default" => 95.5},
          "verified" => %{"type" => "boolean", "default" => true}
        },
        "required" => []
      }
    }

    request =
      Task.async(fn ->
        Session.request_peer(
          server_name,
          Client.info!(client).session_id,
          "elicitation/create",
          params,
          timeout_ms: 2_000
        )
      end)

    assert_receive {:standalone_elicitation, "Accept the defaults", ^params}, 1_000

    assert {:ok,
            %{
              "action" => "accept",
              "content" => %{
                "name" => "John Doe",
                "score" => 95.5,
                "verified" => true
              }
            }} = Task.await(request, 3_000)

    assert :ok = Client.disconnect!(client)
  end

  test "connected client reuses authenticated credentials for protected callbacks" do
    test_pid = self()

    server_name =
      "client-http-protected-callbacks-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        access_token: "dev-token",
        sampling_handler: fn messages, params ->
          send(test_pid, {:protected_sampling_handler_called, messages, params})
          sampling_result("sampled")
        end,
        elicitation_handler: fn message, params ->
          send(test_pid, {:protected_elicitation_handler_called, message, params})
          {:accept, %{"value" => "Alice"}}
        end
      )

    sample_task =
      Task.async(fn ->
        Client.call_tool!(client, "sample", %{})
      end)

    assert_receive {:protected_sampling_handler_called, _messages, _params}, 1_000

    assert %{structured_content: %{"content" => %{"text" => "sampled"}}} =
             Task.await(sample_task, 6_000)

    elicitation_task =
      Task.async(fn ->
        Client.call_tool!(client, "ask_name", %{})
      end)

    assert_receive {:protected_elicitation_handler_called, "What is your name?",
                    %{
                      "requestedSchema" => %{
                        "type" => "object",
                        "properties" => %{"value" => %{"type" => "string"}},
                        "required" => ["value"]
                      }
                    }},
                   1_000

    assert %{structured_content: %{"name" => "Alice"}} = Task.await(elicitation_task, 6_000)
  end

  test "request-scoped HTTP state still uses a server-issued session stream" do
    server_name =
      "client-http-request-state-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name,
        allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
        state_scope: :request
      )

    client =
      connect!(url,
        protocol_version: "2025-11-25",
        session_stream: false
      )

    assert is_binary(Client.info!(client).session_id)
    assert :ok = Client.open_session_stream!(client)
    assert_eventually(fn -> Client.info!(client).session_stream_open? end)
    assert Client.info!(client).session_stream_open?
  end

  test "connected client manages protected task lifecycle over HTTP" do
    parent = self()
    server_name = "client-http-tasks-" <> Integer.to_string(System.unique_integer([:positive]))

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
      fn _arguments, _ctx ->
        send(parent, {:confirm_started, self()})

        receive do
          :release -> %{approved: true}
        end
      end,
      task: true
    )
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(url,
        protocol_version: "2025-11-25",
        access_token: "dev-token"
      )

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "confirm"} =
             task = Client.call_tool_task!(client, "confirm", %{}, task: true)

    assert %{items: [%{"taskId" => ^task_id}], next_cursor: nil} = Client.list_tasks!(client)
    assert %{"taskId" => ^task_id} = client |> Client.track_task!(task_id) |> RemoteTask.fetch!()
    assert %{"taskId" => ^task_id} = RemoteTask.fetch!(task)
    assert %{"taskId" => ^task_id} = RemoteTask.status!(task)

    assert_receive {:confirm_started, confirm}, 1_000
    send(confirm, :release)
    assert_eventually(fn -> RemoteTask.fetch!(task)["status"] == "completed" end)
    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait!(task)

    assert %{
             "structuredContent" => %{"approved" => true},
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
             }
           } = result = RemoteTask.result!(task).raw

    assert ^result = RemoteTask.result!(task).raw
    assert :ok = Client.disconnect!(client)
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

    start_server!(server)

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:session_stream_notification, payload})
        end
      )

    assert_eventually(fn -> Client.info!(client).session_stream_open? end)
    assert Client.info!(client).session_stream_open?

    session_id = Client.info!(client).session_id

    assert %RemoteTask{task_id: task_id, kind: :tool, target: "wait"} =
             task = Client.call_tool_task!(client, "wait", %{}, task: true)

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

    assert %{"taskId" => ^task_id, "status" => "completed"} = RemoteTask.wait!(task)
    assert_eventually(fn -> RemoteTask.fetch!(task)["status"] == "completed" end)
    assert :ok = Client.disconnect!(client)
  end

  test "notification handler failures do not fail tool calls" do
    server_name =
      "client-http-notification-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("notify", fn _arguments, ctx ->
      Context.log(ctx, :info, "hello from server")
      Context.report_progress(ctx, 1, 1, "done")
      %{ok: true}
    end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    parent = self()

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        log_handler: fn _payload -> raise "boom" end,
        progress_handler: fn _payload -> raise "boom" end,
        notification_handler: fn
          %{"method" => "notifications/progress"} -> send(parent, :progress_dispatched)
          _payload -> raise "boom"
        end
      )

    # Handlers run in order outside the connection; a failing one is logged
    # and the next still runs.
    log =
      capture_log(fn ->
        assert %{structured_content: %{"ok" => true}} =
                 Client.call_tool!(client, "notify", %{}, progress_token: "token-1")

        assert_receive :progress_dispatched, 1_000
      end)

    assert log =~ "MCP client notification handler failed"
    assert Client.connected?(client)
  end

  test "connected client can update auth and handlers after connect" do
    parent = self()

    server_name =
      "client-http-runtime-updates-" <> Integer.to_string(System.unique_integer([:positive]))

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
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        auto_initialize: false
      )

    :ok =
      Client.set_auth!(client, headers: [{"x-trace-id", "trace-123"}], access_token: "dev-token")

    Client.set_handler!(client, :log_handler, fn payload ->
      send(parent, {:runtime_log, payload})
    end)

    Client.set_handler!(client, :progress_handler, fn payload ->
      send(parent, {:runtime_progress, payload})
    end)

    Client.set_handler!(client, :notification_handler, fn payload ->
      send(parent, {:runtime_notification, payload})
    end)

    Client.set_handler!(client, :sampling_handler, fn messages, _params ->
      send(parent, {:runtime_sampling, messages})
      sampling_result("runtime sampled")
    end)

    assert_raise ArgumentError, ~r/unknown handler :task_handler, the handlers are: \[/, fn ->
      Client.set_handler(client, :task_handler, fn _status -> :ok end)
    end

    assert_raise ArgumentError, "log_handler must be a function, got: :log", fn ->
      Client.set_handler(client, :log_handler, :log)
    end

    assert is_map(Client.initialize!(client))

    assert %{structured_content: %{"x-trace-id" => "trace-123"}} =
             Client.call_tool!(client, "headers", %{})

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "notify", %{}, progress_token: "token-2")

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

    assert %{structured_content: %{"content" => %{"text" => "runtime sampled"}}} =
             Client.call_tool!(client, "sample", %{})

    assert_receive {:runtime_sampling,
                    [%{"content" => %{"text" => "Reply with runtime sampled"}}]},
                   1_000
  end

  test "server-initiated requests on an HTTP stream never copy connection state to workers" do
    server_name = unique_name("snapshot")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("sampled", fn _arguments, context ->
      sampled = Context.sample(context, "continue", timeout_ms: 2_000)
      %{"model" => sampled["model"]}
    end)
    |> start_server!()

    %{url: url} = start_http!(server_name)

    client =
      connect!(url,
        protocol_version: "2025-11-25",
        sampling_handler: fn _messages, _params ->
          %{
            "role" => "assistant",
            "model" => "snapshot-model",
            "content" => %{"type" => "text", "text" => "ok"}
          }
        end
      )

    :erlang.trace(client.pid, true, [:send])

    assert %{structured_content: %{"model" => "snapshot-model"}} =
             Client.call_tool!(client, "sampled", %{})

    :erlang.trace(client.pid, false, [:send])

    leaked =
      for {:trace, _pid, :send, message, _to} <- drain_trace_messages(),
          contains_client_state?(message),
          do: message

    assert leaked == []
  end

  test "atom keys and atom values from the caller and its handlers reach the server as JSON" do
    server_name = unique_name("atom-keys")

    sampling = %{
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}],
        "maxTokens" => 10
      }
    }

    elicitation = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Confirm?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"answer" => %{"type" => "string"}},
          "required" => ["answer"]
        }
      }
    }

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "integer"},
          "nested" => %{"type" => "object", "properties" => %{"b" => %{"type" => "string"}}},
          "mode" => %{"type" => "string", "enum" => ["fast"]}
        },
        "required" => ["a"],
        "additionalProperties" => false
      }
    )
    |> FastestMCP.add_tool("ask", fn _arguments, ctx ->
      case Context.input_responses(ctx) do
        responses when map_size(responses) == 0 ->
          FastestMCP.InputRequiredResult.new(%{"sample" => sampling, "confirm" => elicitation})

        responses ->
          responses
      end
    end)
    |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end,
      arguments: [%{name: "name", required: true, completion: ["Ada", "Grace"]}]
    )
    |> start_server!()

    %{url: url} = start_http!(server_name)

    client =
      connect!(url,
        sampling_handler: fn _messages, _params ->
          %{role: :assistant, model: "test-model", content: %{type: :text, text: "sampled"}}
        end,
        elicitation_handler: fn _message, _params -> {:accept, %{answer: "yes"}} end
      )

    assert Client.call_tool!(client, "echo", %{a: 1, nested: %{b: "x"}, mode: :fast}).structured_content ==
             %{"a" => 1, "nested" => %{"b" => "x"}, "mode" => "fast"}

    assert {:error, %Error{code: :invalid_params}} = Client.call_tool(client, "echo", %{a: "one"})

    assert %{"structuredContent" => %{"a" => 2}} =
             Client.request!(client, "tools/call", %{name: "echo", arguments: %{a: 2}})

    assert %{"messages" => [%{"content" => %{"text" => "Hello, Ada!"}}]} =
             Client.render_prompt!(client, "greet", %{name: :Ada})

    assert %{"values" => ["Ada"]} =
             Client.complete!(client, %{type: "ref/prompt", name: "greet"}, %{
               name: :name,
               value: "A"
             })

    assert %{
             "sample" => %{"content" => %{"text" => "sampled"}, "role" => "assistant"},
             "confirm" => %{"action" => "accept", "content" => %{"answer" => "yes"}}
           } = Client.call_tool!(client, "ask", %{}).structured_content

    legacy = connect!(url, protocol_version: "2025-11-25")

    assert Client.call_tool!(legacy, "echo", %{a: 3, nested: %{b: "y"}}).structured_content ==
             %{"a" => 3, "nested" => %{"b" => "y"}}
  end

  test "read_resource/3 returns the whole result on both protocol versions" do
    server_name = unique_name("read-shape")

    FastestMCP.server(server_name)
    |> FastestMCP.add_resource("notes://1", fn _args, _ctx -> %{id: "1", title: "Release"} end)
    |> FastestMCP.add_resource("notes://plain", fn _args, _ctx -> "plain text" end)
    |> start_server!()

    for version <- ["2026-07-28", "2025-11-25"] do
      client = connect!({:in_process, server_name}, protocol_version: version)

      assert %{"contents" => [%{"uri" => "notes://1", "text" => json}]} =
               Client.read_resource!(client, "notes://1")

      assert JSON.decode!(json) == %{"id" => "1", "title" => "Release"}

      assert %{"contents" => [%{"uri" => "notes://plain", "text" => "plain text"}]} =
               Client.read_resource!(client, "notes://plain")
    end
  end

  test "HTTP errors carry clean messages and the server's code" do
    server_name = unique_name("http-errors")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn a, _ -> a end)
    |> start_server!()

    %{url: guarded} = start_http!(server_name, allowed_hosts: ["mcp.example.com"])

    assert {:error, %Error{code: :forbidden, message: "request host is not allowed"} = forbidden} =
             Client.connect(guarded, protocol_version: "2026-07-28")

    assert forbidden.details.status == 403

    %{url: missing} = serve!(NotFoundPlug)

    assert {:error, %Error{code: :not_found, message: message, details: %{status: 404}}} =
             Client.connect(missing, protocol_version: "2026-07-28")

    assert message == "server/discover failed with HTTP 404 Not Found"
  end

  test "a 504 without a JSON-RPC body, as from a proxy, is a timeout" do
    %{url: url} = serve!(GatewayTimeoutPlug)

    assert {:error, %Error{code: :timeout, message: message, details: %{status: 504}}} =
             Client.connect(url, protocol_version: "2026-07-28")

    assert message == "server/discover failed with HTTP 504 Gateway Timeout"
  end

  defp sampling_result(text) do
    %{
      "role" => "assistant",
      "model" => "test-model",
      "content" => %{"type" => "text", "text" => text}
    }
  end

  defp drain_trace_messages(acc \\ []) do
    receive do
      {:trace, _pid, :send, _message, _to} = trace -> drain_trace_messages([trace | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp contains_client_state?(%FastestMCP.Client.Connection.State{}), do: true

  defp contains_client_state?(%_{} = struct),
    do: struct |> Map.from_struct() |> contains_client_state?()

  defp contains_client_state?(map) when is_map(map),
    do:
      Enum.any?(map, fn {key, value} ->
        contains_client_state?(key) or contains_client_state?(value)
      end)

  defp contains_client_state?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> contains_client_state?()

  defp contains_client_state?([head | tail]),
    do: contains_client_state?(head) or contains_client_state?(tail)

  defp contains_client_state?(_term), do: false

  # The JSON value of a resource's one text content.
  defp read_json!(client, uri, opts \\ []) do
    assert %{"contents" => [%{"text" => text}]} = Client.read_resource!(client, uri, opts)
    JSON.decode!(text)
  end
end
