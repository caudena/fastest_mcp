defmodule FastestMCP.ClientInProcessTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Extensions

  test "modern client discovers and correlates concurrent requests through the shared engine" do
    server_name = unique_name("modern")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
      |> FastestMCP.add_tool("delay", fn %{"value" => value, "delay" => delay}, _context ->
        Process.sleep(delay)
        %{"value" => value}
      end)

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name},
        client_info: %{"name" => "in-process-test", "version" => "1.0.0"}
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert Client.protocol_version(client) == "2026-07-28"
    assert Client.session_id(client) == nil
    assert Client.initialize_result(client) == nil
    assert %{"supportedVersions" => versions} = Client.discovery_result(client)
    assert "2026-07-28" in versions

    slow = delayed_request(client, "slow", 80)
    fast = delayed_request(client, "fast", 1)
    middle = delayed_request(client, "middle", 30)

    assert [slow.request_id, fast.request_id, middle.request_id] |> Enum.uniq() |> length() == 3

    assert get_in(Client.await(fast, 1_000), ["structuredContent", "value"]) == "fast"
    assert get_in(Client.await(middle, 1_000), ["structuredContent", "value"]) == "middle"
    assert get_in(Client.await(slow, 1_000), ["structuredContent", "value"]) == "slow"

    assert %{"structuredContent" => %{"message" => "hello"}} =
             Client.call_tool(client, "echo", %{"message" => "hello"})
  end

  test "legacy client initializes through the same stdio session lifecycle" do
    server_name = unique_name("legacy")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name}, protocol_version: "2025-11-25")

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert Client.protocol_version(client) == "2025-11-25"
    assert Client.session_id(client) == nil
    assert is_map(Client.initialize_result(client))
    assert Client.call_tool(client, "echo", %{"era" => "legacy"}) == %{"era" => "legacy"}

    error = assert_raise Error, fn -> Client.open_session_stream(client) end
    assert error.code == :bad_request
  end

  test "legacy callbacks and per-call progress use the existing client routers" do
    server_name = unique_name("legacy-callbacks")
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sample", fn _arguments, context ->
        Context.sample(context, "Reply with sampled")
      end)
      |> FastestMCP.add_tool("ask_name", fn _arguments, context ->
        case Context.elicit(context, "What is your name?", :string) do
          %Accepted{data: name} -> %{name: name}
        end
      end)
      |> FastestMCP.add_tool("progress", fn _arguments, context ->
        :ok = Context.report_progress(context, 1, 2, "started")
        :ok = Context.report_progress(context, 2, 2, "finished")
        %{done: true}
      end)

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name},
        protocol_version: "2025-11-25",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling, messages, params})
          sampling_result("sampled")
        end,
        elicitation_handler: fn message, params ->
          send(test_pid, {:elicitation, message, params})
          {:accept, %{"value" => "Alice"}}
        end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert "sampled" = Client.call_tool(client, "sample", %{})
    assert_receive {:sampling, [%{"content" => %{"text" => "Reply with sampled"}}], _}, 1_000

    assert %{"name" => "Alice"} = Client.call_tool(client, "ask_name", %{})
    assert_receive {:elicitation, "What is your name?", _}, 1_000

    assert %{"done" => true} =
             Client.call_tool(client, "progress", %{},
               progress_handler: fn params -> send(test_pid, {:progress, params}) end
             )

    assert_receive {:progress, %{"progress" => 1, "total" => 2, "message" => "started"}},
                   1_000

    assert_receive {:progress, %{"progress" => 2, "total" => 2, "message" => "finished"}},
                   1_000
  end

  test "modern subscriptions remain open while ordinary requests are cancelled" do
    server_name = unique_name("subscriptions")
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("status://in-process", fn _arguments, _context -> %{ok: true} end)
      |> FastestMCP.add_tool("notify", fn _arguments, context ->
        :ok = Context.notify_resource_updated(context, "status://in-process")
        %{notified: true}
      end)
      |> FastestMCP.add_tool("block", fn _arguments, _context ->
        send(test_pid, {:blocking_worker, self()})

        receive do
          :release -> %{released: true}
        end
      end)

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name},
        protocol_version: "2026-07-28",
        notification_handler: fn message -> send(test_pid, {:global_notification, message}) end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    listener =
      Client.listen(
        client,
        %{"resourceSubscriptions" => ["status://in-process"]},
        on_notification: fn message -> send(test_pid, {:subscription_notification, message}) end
      )

    assert_receive {:subscription_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => subscription_id
                        }
                      }
                    }},
                   1_000

    assert subscription_id == listener.request_id

    blocked =
      Client.request_async(client, "tools/call", %{
        "name" => "block",
        "arguments" => %{}
      })

    assert_receive {:blocking_worker, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    assert :ok = Client.cancel(blocked, "test cancellation")

    error = assert_raise Error, fn -> Client.await(blocked, 1_000) end
    assert error.code == :cancelled
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000

    assert get_in(Client.call_tool(client, "notify", %{}), ["structuredContent", "notified"]) ==
             true

    assert_receive {:subscription_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "status://in-process",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^subscription_id
                        }
                      }
                    }},
                   1_000

    assert_receive {:global_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "status://in-process"}
                    }},
                   1_000

    assert :ok = Client.cancel(listener, "test complete")
    assert Client.connected?(client)
  end

  test "modern transparent tasks and task listeners reuse the existing task driver" do
    server_name = unique_name("tasks")
    test_pid = self()
    task_extensions = %{Extensions.tasks() => %{}}

    server =
      FastestMCP.server(server_name, extensions: task_extensions)
      |> FastestMCP.add_tool(
        "deferred",
        fn arguments, _context ->
          send(test_pid, {:task_worker, self(), arguments["value"]})

          receive do
            :release -> arguments
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name},
        protocol_version: "2026-07-28",
        extensions: task_extensions
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    transparent =
      Task.async(fn ->
        Client.call_tool(client, "deferred", %{"value" => "transparent"}, task_timeout_ms: 2_000)
      end)

    assert_receive {:task_worker, transparent_worker, "transparent"}, 1_000
    send(transparent_worker, :release)
    assert %{"value" => "transparent"} = Task.await(transparent, 3_000)
    refute Client.session_stream_open?(client)

    assert %RemoteTask{task_id: task_id} =
             task = Client.call_tool_task(client, "deferred", %{"value" => "handle"})

    assert_receive {:task_worker, handle_worker, "handle"}, 1_000

    listener =
      Client.listen(client, %{"taskIds" => [task_id]},
        on_notification: fn message -> send(test_pid, {:task_notification, message}) end
      )

    assert_receive {:task_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   1_000

    result_waiter = Task.async(fn -> RemoteTask.result(task, timeout_ms: 2_000) end)
    send(handle_worker, :release)

    assert_receive {:task_notification,
                    %{
                      "method" => "notifications/tasks",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   1_000

    assert %{"value" => "handle"} = Task.await(result_waiter, 3_000)
    assert :ok = Client.cancel(listener, "test complete")
  end

  test "current and per-call auth input traverses normal authentication" do
    server_name = unique_name("auth")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn input, _context ->
        case input["token"] do
          token when token in ["alpha", "beta", "gamma"] ->
            {:ok, %{principal: {"in-process-test", token}, auth: %{token: token}}}

          _other ->
            {:error, :unauthorized}
        end
      end)
      |> FastestMCP.add_tool("principal", fn _arguments, context ->
        %{principal: context.principal}
      end)

    start_server!(server_name, server)

    client = Client.connect!({:in_process, server_name}, auth_input: %{token: "alpha"})
    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert get_in(Client.call_tool(client, "principal", %{}), ["structuredContent", "principal"]) ==
             ["in-process-test", "alpha"]

    assert :ok = Client.set_auth_input(client, %{token: "beta"})

    assert get_in(Client.call_tool(client, "principal", %{}), ["structuredContent", "principal"]) ==
             ["in-process-test", "beta"]

    assert get_in(
             Client.request(
               client,
               "tools/call",
               %{"name" => "principal", "arguments" => %{}},
               auth_input: %{token: "gamma"}
             ),
             ["structuredContent", "principal"]
           ) == ["in-process-test", "gamma"]

    error =
      assert_raise Error, fn ->
        Client.request(
          client,
          "tools/call",
          %{"name" => "principal", "arguments" => %{}},
          authorization: "Bearer secret"
        )
      end

    assert error.code == :invalid_params
  end

  test "in-process auth is verified without retaining wire auth in public request metadata" do
    server_name = unique_name("private-auth-metadata")
    secret = "in-process-wire-auth-secret"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn input, _context ->
        if input["credential"] == secret do
          {:ok,
           %{
             principal: {"in-process-test", "stable-user"},
             auth: %{token: secret, tenant: "acme"}
           }}
        else
          {:error, :unauthorized}
        end
      end)
      |> FastestMCP.add_tool("inspect_auth_metadata", fn _arguments, context ->
        envelope = context.request_metadata[:jsonrpc_envelope]

        %{
          retained_wire_auth: get_in(envelope, ["params", "_meta", "fastestmcp", "auth"]),
          request_context: inspect(Context.request_context(context)),
          context: inspect(context)
        }
      end)

    start_server!(server_name, server)

    client =
      Client.connect!({:in_process, server_name},
        auth_input: %{"credential" => secret}
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert %{
             "structuredContent" => %{
               "retained_wire_auth" => nil,
               "request_context" => request_context,
               "context" => context
             }
           } = Client.call_tool(client, "inspect_auth_metadata", %{})

    refute request_context =~ secret
    refute context =~ secret
  end

  test "HTTP, SSE, and stdio-process options are rejected" do
    server_name = unique_name("invalid-options")
    start_server!(server_name, FastestMCP.server(server_name))

    for {option, value} <- [
          oauth: [],
          headers: [{"x-test", "value"}],
          authorization: "Bearer token",
          access_token: "token",
          session_id: "not-client-owned",
          session_stream: true,
          sse_reconnect: false,
          max_sse_event_bytes: 1_024,
          env: %{"VALUE" => "1"},
          legacy_stdio_auth_metadata: true,
          stdio_restart: false
        ] do
      assert {:error, %Error{code: :invalid_params, details: %{unsupported_options: [^option]}}} =
               Client.connect({:in_process, server_name}, [{option, value}])
    end
  end

  test "connection fails clearly when the named server is not running" do
    server_name = unique_name("missing")

    assert {:error,
            %Error{
              code: :bad_request,
              message: "in-process server is not running",
              details: %{server_name: ^server_name}
            }} = Client.connect({:in_process, server_name})
  end

  test "server shutdown closes the client and fails in-flight requests" do
    server_name = unique_name("shutdown")
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("block", fn _arguments, _context ->
        send(test_pid, :block_started)
        Process.sleep(5_000)
        %{completed: true}
      end)

    start_server!(server_name, server)
    client = Client.connect!({:in_process, server_name})

    request =
      Client.request_async(
        client,
        "tools/call",
        %{"name" => "block", "arguments" => %{}},
        timeout_ms: 10_000
      )

    assert_receive :block_started, 1_000
    assert :ok = FastestMCP.stop_server(server_name)

    error = assert_raise Error, fn -> Client.await(request, 2_000) end
    assert error.code == :internal_error
    assert eventually(fn -> not Client.connected?(client) end)
  end

  defp start_server!(server_name, server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
  end

  defp unique_name(suffix) do
    "client-in-process-#{suffix}-#{System.unique_integer([:positive])}"
  end

  defp sampling_result(text) do
    %{
      "role" => "assistant",
      "model" => "test-model",
      "content" => %{"type" => "text", "text" => text}
    }
  end

  defp delayed_request(client, value, delay) do
    Client.request_async(
      client,
      "tools/call",
      %{"name" => "delay", "arguments" => %{"value" => value, "delay" => delay}}
    )
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: fun.()
end
