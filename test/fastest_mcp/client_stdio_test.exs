defmodule FastestMCP.ClientStdioTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.StdioProcess
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Test.StdioProcessGroupFixture

  defmodule UnprovenCloseTransport do
    @behaviour FastestMCP.Client.Transport

    @impl true
    def open(_transport, _owner, _opts), do: {:error, :unsupported}

    @impl true
    def connected?(_transport), do: true

    @impl true
    def send_envelope(_transport, _envelope), do: :ok

    @impl true
    def close(_transport), do: {:error, :process_still_alive}
  end

  test "stdio omitted env inherits while explicit env replaces the parent environment" do
    previous = System.get_env("FASTMCP_AMBIENT_TEST")
    System.put_env("FASTMCP_AMBIENT_TEST", "ambient")

    on_exit(fn ->
      if previous,
        do: System.put_env("FASTMCP_AMBIENT_TEST", previous),
        else: System.delete_env("FASTMCP_AMBIENT_TEST")
    end)

    assert run_env_probe(:inherit) =~ "FASTMCP_AMBIENT_TEST=ambient"
    assert run_env_probe({:replace, []}) == ""
    assert run_env_probe({:replace, [{"ONLY_THIS", "value"}]}) == "ONLY_THIS=value\n"
  end

  test "stdio replacement environments reject ambiguous or unbounded entries before spawn" do
    target = {:stdio, "/usr/bin/env", []}

    assert {:error, %Error{code: :invalid_params, message: duplicate_message}} =
             Client.connect(target, env: [{"TOKEN", "one"}, {"TOKEN", "two"}])

    assert duplicate_message == "stdio env contains duplicate variable names"

    for environment <- [
          [{"BAD-NAME", "value"}],
          [{"TOKEN", false}],
          [{"TOKEN", nil}]
        ] do
      assert {:error, %Error{code: :invalid_params, message: invalid_message}} =
               Client.connect(target, env: environment)

      assert invalid_message == "stdio env must be a map or keyword list of scalar values"
    end

    assert {:error, %Error{code: :invalid_params, message: oversized_message}} =
             Client.connect(target, env: %{"TOKEN" => String.duplicate("x", 65_536)})

    assert oversized_message == "stdio env exceeds the bounded environment size"
  end

  test "stdio bounds an unterminated response frame" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    script = """
    IO.read(:stdio, :line)
    IO.binwrite(:stdio, String.duplicate("x", 4_097))
    Process.sleep(5_000)
    """

    assert {:error,
            %Error{
              code: :bad_request,
              message: "MCP response exceeds configured size limit",
              details: %{
                max_response_bytes: 4_096,
                observed_bytes: observed_bytes,
                terminal_response_observed: false
              }
            }} =
             Client.connect({:stdio, elixir, ["-e", script]},
               protocol_version: "2025-11-25",
               max_response_bytes: 4_096,
               stdio_restart: false
             )

    assert observed_bytes > 4_096
  end

  test "stdio marks an oversized complete response for the in-flight request as terminal" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    script = ~S'''
    request = IO.read(:stdio, :line)
    [_, id] = Regex.run(~r/"id"\s*:\s*("[^"]+"|[0-9]+)/, request)

    IO.binwrite(
      :stdio,
      "{\"jsonrpc\":\"2.0\",\"id\":" <> id <>
        ",\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{}," <>
        "\"serverInfo\":{\"name\":\"large\",\"version\":\"1\"},\"padding\":\"" <>
        String.duplicate("x", 4_096) <> "\"}}\n"
    )
    '''

    assert {:error,
            %Error{
              code: :bad_request,
              message: "MCP response exceeds configured size limit",
              details: %{terminal_response_observed: true}
            }} =
             Client.connect({:stdio, elixir, ["-e", script]},
               protocol_version: "2025-11-25",
               max_response_bytes: 4_096,
               stdio_restart: false
             )
  end

  test "connected client initializes and calls tools over stdio" do
    server_name = "client-stdio-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      case Client.connect(
             {:stdio, elixir, stdio_server_args(server_name)},
             client_info: %{"name" => "client-stdio-test", "version" => "1.0.0"},
             env: %{
               "ELIXIR_ERL_OPTIONS" => "+fnu",
               "FASTMCP_CHILD_TEST" => "from-client",
               "PATH" => System.fetch_env!("PATH")
             }
           ) do
        {:ok, client} ->
          client

        {:error, error} ->
          flunk(
            "failed to connect stdio client: #{Exception.message(error)} details=#{inspect(error.details)}"
          )
      end

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert Client.connected?(client)
    assert Client.protocol_version(client) == Protocol.current_version()
    assert %{items: tools, next_cursor: nil} = Client.list_tools(client)
    assert Enum.sort(Enum.map(tools, & &1["name"])) == ["child_env", "echo"]

    assert %{"structuredContent" => %{"message" => "hi"}} =
             Client.call_tool(client, "echo", %{"message" => "hi"})

    assert %{"structuredContent" => %{"value" => "from-client"}} =
             Client.call_tool(client, "child_env", %{})
  end

  test "connected client authenticates protected stdio servers" do
    server_name = "client-stdio-auth-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      case Client.connect(
             {:stdio, elixir, protected_stdio_server_args(server_name)},
             access_token: "dev-token",
             legacy_stdio_auth_metadata: true
           ) do
        {:ok, client} ->
          client

        {:error, error} ->
          flunk(
            "failed to connect stdio client: #{Exception.message(error)} details=#{inspect(error.details)}"
          )
      end

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"structuredContent" => %{"sub" => "local-client"}} =
             Client.call_tool(client, "whoami", %{})
  end

  test "stdio authentication metadata is omitted unless the legacy option is explicit" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      Client.connect!(
        {:stdio, elixir, auth_metadata_probe_stdio_server_args()},
        protocol_version: "2025-11-25",
        access_token: "must-not-be-written-to-json-rpc"
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert get_in(Client.initialize_result(client), ["serverInfo", "name"]) == "clean-wire"
  end

  test "stdio clients reject max_in_flight values above one" do
    server_name =
      "client-stdio-capacity-" <> Integer.to_string(System.unique_integer([:positive]))

    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error,
              %Error{
                code: :bad_request,
                details: %{max_in_flight: 2, supported: 1, transport: :stdio}
              }} =
               Client.connect({:stdio, elixir, stdio_server_args(server_name)},
                 protocol_version: "2025-11-25",
                 max_in_flight: 2
               )
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "stdio request timeouts do not crash the client" do
    server_name = "client-stdio-timeout-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      case Client.connect({:stdio, elixir, slow_stdio_server_args(server_name)}) do
        {:ok, client} ->
          client

        {:error, error} ->
          flunk(
            "failed to connect stdio client: #{Exception.message(error)} details=#{inspect(error.details)}"
          )
      end

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    error =
      assert_raise Error, fn ->
        Client.call_tool(client, "slow", %{}, timeout_ms: 10)
      end

    assert error.code == :timeout

    assert Client.connected?(client)

    assert %{"structuredContent" => %{"message" => "hi"}} =
             Client.call_tool(client, "echo", %{"message" => "hi"})
  end

  test "automatic stdio negotiation falls back on the same live process after a non-modern error" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client = Client.connect!({:stdio, elixir, legacy_fallback_stdio_server_args()})
    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert Client.protocol_version(client) == "2025-11-25"
    assert get_in(Client.initialize_result(client), ["serverInfo", "name"]) == "same-process"
    assert %{items: [%{"name" => "fallback-ok"}]} = Client.list_tools(client)
  end

  test "stdio client routes notifications without consuming the matching response" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, interleaved_stdio_server_args()},
        protocol_version: "2025-11-25",
        notification_handler: fn message -> send(test_pid, {:stdio_notification, message}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:stdio_notification,
                    %{
                      "method" => "notifications/message",
                      "params" => %{"level" => "info", "data" => "ready"}
                    }}

    assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools(client)

    assert_receive {:stdio_notification,
                    %{
                      "method" => "notifications/message",
                      "params" => %{"level" => "info", "data" => "listing"}
                    }}
  end

  test "modern stdio demultiplexes concurrent responses while a subscription remains open" do
    server_name =
      "client-stdio-modern-demux-" <>
        Integer.to_string(System.unique_integer([:positive]))

    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, modern_concurrent_stdio_server_args(server_name)},
        protocol_version: "2026-07-28",
        max_in_flight: 4,
        notification_handler: fn message -> send(test_pid, {:global_notification, message}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    listener =
      Client.listen(
        client,
        %{"resourceSubscriptions" => ["status://modern"]},
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
                   2_000

    assert subscription_id == listener.request_id

    slow =
      Client.request_async(client, "tools/call", %{
        "name" => "slow",
        "arguments" => %{}
      })

    fast =
      Client.request_async(client, "tools/call", %{
        "name" => "fast",
        "arguments" => %{}
      })

    assert %{"structuredContent" => %{"name" => "fast"}} = Client.await(fast, 2_000)
    assert %{"structuredContent" => %{"name" => "slow"}} = Client.await(slow, 2_000)

    cancelled =
      Client.request_async(client, "tools/call", %{
        "name" => "slow",
        "arguments" => %{}
      })

    cancelled_id = cancelled.request_id
    assert :ok = Client.cancel(cancelled, "ordinary request cancellation")

    refute_receive {:global_notification,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{"requestId" => ^cancelled_id}
                    }},
                   300

    assert %{items: tools} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "fast"))

    assert_receive {:subscription_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "status://modern",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^subscription_id
                        }
                      }
                    }},
                   2_000

    assert_receive {:global_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "status://modern",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^subscription_id
                        }
                      }
                    }},
                   2_000

    assert :ok = Client.cancel(listener, "test complete")

    assert %{"structuredContent" => %{"name" => "fast"}} =
             client
             |> Client.request_async("tools/call", %{
               "name" => "fast",
               "arguments" => %{}
             })
             |> Client.await(2_000)

    refute_receive {:subscription_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "status://modern"}
                    }},
                   100

    refute_receive {:global_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "status://modern"}
                    }},
                   100

    assert %{items: tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["fast", "slow"]
    assert Client.connected?(client)
  end

  test "modern stdio restarts an exited child and re-establishes subscriptions" do
    server_name =
      "client-stdio-modern-restart-" <>
        Integer.to_string(System.unique_integer([:positive]))

    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, restartable_modern_stdio_server_args(server_name)},
        protocol_version: "2026-07-28",
        stdio_restart: [max_attempts: 3, retry_ms: 10, max_retry_ms: 50]
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert %{"structuredContent" => %{"name" => "fast"}} =
             Client.call_tool(client, "fast", %{})

    catalog_generation = :sys.get_state(client.pid).tool_catalog.generation

    listener =
      Client.listen(
        client,
        %{"resourceSubscriptions" => ["status://restart"]},
        on_notification: fn message -> send(test_pid, {:restart_notification, message}) end
      )

    assert_receive {:restart_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => first_subscription_id
                        }
                      }
                    }},
                   2_000

    crash =
      Client.request_async(client, "tools/call", %{
        "name" => "crash",
        "arguments" => %{}
      })

    assert_raise Error, fn -> Client.await(crash, 3_000) end

    assert_receive {:restart_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => second_subscription_id
                        }
                      }
                    }},
                   5_000

    refute second_subscription_id == first_subscription_id
    assert first_subscription_id == listener.request_id

    restarted_state = :sys.get_state(client.pid)
    assert restarted_state.tool_catalog.generation > catalog_generation
    refute restarted_state.tool_catalog_ready?

    assert %{"structuredContent" => %{"name" => "fast"}} =
             Client.call_tool(client, "fast", %{})

    assert_receive {:restart_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "status://restart",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^second_subscription_id
                        }
                      }
                    }},
                   2_000

    assert Client.connected?(client)
    assert :ok = Client.cancel(listener, "test complete")
  end

  test "process-group stdio restart and disconnect terminate spawned descendants" do
    if StdioProcess.signal_supported?() and System.find_executable("cc") do
      {launcher, launcher_directory} = StdioProcessGroupFixture.build!()

      marker =
        Path.join(
          System.tmp_dir!(),
          "fastest-mcp-descendants-#{System.unique_integer([:positive])}"
        )

      server_name =
        "client-stdio-process-group-" <>
          Integer.to_string(System.unique_integer([:positive]))

      elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

      target =
        descendant_spawning_modern_target(
          elixir,
          descendant_spawning_modern_server_args(server_name),
          marker
        )

      client =
        Client.connect!(
          target,
          protocol_version: "2026-07-28",
          stdio_restart: [max_attempts: 3, retry_ms: 10, max_retry_ms: 50],
          stdio_process_group: [
            launcher: launcher,
            launcher_args: ["cwd", "device", "minor", "inode"]
          ]
        )

      on_exit(fn ->
        if Client.connected?(client) do
          :sys.replace_state(client.pid, fn state ->
            put_in(state.transport.adapter, FastestMCP.Client.Transport.Stdio)
          end)

          Client.disconnect(client)
        end

        marker
        |> descendant_pids()
        |> Enum.each(&kill_if_alive/1)

        File.rm(marker)
        File.rm_rf!(launcher_directory)
      end)

      [first_descendant] = wait_for_descendants(marker, 1)
      initial_generation = :sys.get_state(client.pid).transport.generation
      assert StdioProcess.alive?(first_descendant)

      crash =
        Client.request_async(client, "tools/call", %{
          "name" => "crash",
          "arguments" => %{}
        })

      assert_raise Error, fn -> Client.await(crash, 3_000) end
      wait_for_stdio_generation(client.pid, initial_generation + 1)

      [^first_descendant, second_descendant] = wait_for_descendants(marker, 2)
      wait_until_dead(first_descendant)
      assert StdioProcess.alive?(second_descendant)

      original_adapter = :sys.get_state(client.pid).transport.adapter

      :sys.replace_state(client.pid, fn state ->
        put_in(state.transport.adapter, UnprovenCloseTransport)
      end)

      assert {:error, :process_still_alive} = Client.disconnect_with_evidence(client)
      assert Process.alive?(client.pid)
      assert StdioProcess.alive?(second_descendant)

      :sys.replace_state(client.pid, fn state ->
        put_in(state.transport.adapter, original_adapter)
      end)

      assert :ok = Client.disconnect_with_evidence(client)
      wait_until_dead(second_descendant)
    end
  end

  test "supervised clients expose an explicit restart policy" do
    target = {:stdio, "/usr/bin/env", []}

    assert %{restart: :permanent} = Client.child_spec(target: target)

    assert %{restart: :temporary, start: {Client, :start_link, [start_opts]}} =
             Client.child_spec(target: target, restart: :temporary)

    refute Keyword.has_key?(start_opts, :restart)

    assert_raise ArgumentError, ~r/client child restart/, fn ->
      Client.child_spec(target: target, restart: :invalid)
    end
  end

  test "modern stdio stops cleanly after bounded restart attempts are exhausted" do
    server_name =
      "client-stdio-modern-restart-exhaustion-" <>
        Integer.to_string(System.unique_integer([:positive]))

    marker =
      Path.join(
        System.tmp_dir!(),
        "fastest-mcp-stdio-restart-#{System.unique_integer([:positive])}"
      )

    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, exhausting_modern_stdio_server_args(server_name, marker)},
        protocol_version: "2026-07-28",
        stdio_restart: [max_attempts: 2, retry_ms: 10, max_retry_ms: 20]
      )

    client_ref = Process.monitor(client.pid)

    on_exit(fn ->
      File.rm(marker)
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    listener =
      Client.listen(client, %{"resourceSubscriptions" => ["status://restart"]},
        on_notification: fn message -> send(test_pid, {:exhaustion_notification, message}) end
      )

    assert_receive {:exhaustion_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   2_000

    crash =
      Client.request_async(client, "tools/call", %{
        "name" => "crash",
        "arguments" => %{}
      })

    assert_raise Error, fn -> Client.await(crash, 3_000) end
    assert_raise Error, fn -> Client.await(listener, 5_000) end

    assert_receive {:DOWN, ^client_ref, :process, _pid, :normal}, 5_000
    refute Client.connected?(client)
  end

  test "task progress retains token ownership, stays monotonic, and cleans up at terminal" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, task_progress_stdio_server_args()},
        protocol_version: "2025-11-25",
        progress_handler: fn params -> send(test_pid, {:task_progress, params}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %FastestMCP.Client.Task{task_id: "remote-progress-task"} =
             Client.call_tool(client, "background", %{},
               task: true,
               progress_token: "retained-progress"
             )

    assert_receive {:task_progress,
                    %{
                      "progressToken" => "retained-progress",
                      "progress" => 1,
                      "total" => 3
                    }}

    assert_receive {:task_progress, %{"progressToken" => "retained-progress", "progress" => 2}}

    assert_receive {:task_progress, %{"progressToken" => "retained-progress", "progress" => 4}}

    refute_receive {:task_progress, _params}, 100

    error =
      assert_raise Error, fn ->
        Client.request_async(client, "ping", %{
          "_meta" => %{"progressToken" => "retained-progress"}
        })
      end

    assert error.code == :invalid_params

    # The probe emits a terminal task notification before answering ping.
    assert %{} = Client.ping(client)

    request =
      Client.request_async(client, "ping", %{
        "_meta" => %{"progressToken" => "retained-progress"}
      })

    assert %{} = Client.await(request)
  end

  defp stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_tool("child_env", fn _arguments, _ctx ->
        %{"value" => System.get_env("FASTMCP_CHILD_TEST")}
      end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp slow_stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_tool("slow", fn _arguments, _ctx ->
        Process.sleep(100)
        %{ok: true}
      end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp legacy_fallback_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    write = fn message -> IO.puts(JSON.encode!(message)) end

    loop = fn loop ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        line ->
          request = JSON.decode!(line)

          case request["method"] do
            "server/discover" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "error" => %{"code" => -32042, "message" => "legacy-only process"}
              })

            "initialize" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => "2025-11-25",
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "same-process", "version" => "1.0.0"}
                }
              })

            "notifications/initialized" ->
              :ok

            "tools/list" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "tools" => [
                    %{"name" => "fallback-ok", "inputSchema" => %{"type" => "object"}}
                  ]
                }
              })
          end

          loop.(loop)
      end
    end

    loop.(loop)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp modern_concurrent_stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("fast", fn _arguments, ctx ->
        FastestMCP.Context.notify_resource_updated(ctx, "status://modern")
        %{"name" => "fast"}
      end)
      |> FastestMCP.add_tool("slow", fn _arguments, _ctx ->
        Process.sleep(150)
        %{"name" => "slow"}
      end)
      |> FastestMCP.add_resource("status://modern", fn _arguments, _ctx -> %{ok: true} end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp restartable_modern_stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("crash", fn _arguments, _ctx -> System.halt(17) end)
      |> FastestMCP.add_tool("fast", fn _arguments, ctx ->
        FastestMCP.Context.notify_resource_updated(ctx, "status://restart")
        %{"name" => "fast"}
      end)
      |> FastestMCP.add_resource("status://restart", fn _arguments, _ctx -> %{ok: true} end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp descendant_spawning_modern_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("crash", fn _arguments, _ctx -> System.halt(17) end)
      |> FastestMCP.add_tool("fast", fn _arguments, _ctx -> %{"name" => "fast"} end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp descendant_spawning_modern_target(elixir, server_args, marker) do
    shell = System.find_executable("sh") || flunk("sh executable not found on PATH")

    wrapper = """
    marker=$1
    shift
    (trap '' TERM HUP; while :; do sleep 1; done) </dev/null >/dev/null 2>&1 &
    printf '%s\\n' "$!" >> "$marker"
    exec "$@"
    """

    {:stdio, shell, ["-c", wrapper, "stdio-wrapper", marker, elixir | server_args]}
  end

  defp exhausting_modern_stdio_server_args(server_name, marker) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    if File.exists?(#{inspect(marker)}), do: System.halt(19)

    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("crash", fn _arguments, _ctx ->
        File.write!(#{inspect(marker)}, "crashed")
        System.halt(17)
      end)
      |> FastestMCP.add_resource("status://restart", fn _arguments, _ctx -> %{ok: true} end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp protected_stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
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
      |> FastestMCP.add_tool("whoami", fn _arguments, ctx -> ctx.principal end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp interleaved_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    write = fn message -> IO.puts(JSON.encode!(message)) end

    loop = fn loop ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        line ->
          request = JSON.decode!(line)

          case request["method"] do
            "initialize" ->
              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/message",
                "params" => %{"level" => "info", "data" => "ready"}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => "2025-11-25",
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "interleaved", "version" => "1.0.0"}
                }
              })

            "tools/list" ->
              write.(%{"jsonrpc" => "2.0", "id" => "stale", "result" => %{}})

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/message",
                "params" => %{"level" => "info", "data" => "listing"}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "tools" => [
                    %{"name" => "echo", "inputSchema" => %{"type" => "object"}}
                  ]
                }
              })

            _other ->
              :ok
          end

          loop.(loop)
      end
    end

    loop.(loop)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp auth_metadata_probe_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    loop = fn loop ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        line ->
          request = JSON.decode!(line)

          if request["method"] == "initialize" do
            auth = get_in(request, ["params", "_meta", "fastestmcp", "auth"])

            IO.puts(JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{},
                "serverInfo" => %{
                  "name" => if(auth, do: "injected-wire", else: "clean-wire"),
                  "version" => "1.0.0"
                }
              }
            }))
          end

          loop.(loop)
      end
    end

    loop.(loop)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp task_progress_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    write = fn message -> IO.puts(JSON.encode!(message)) end
    timestamp = "2026-08-03T00:00:00Z"

    task = fn status ->
      %{
        "taskId" => "remote-progress-task",
        "status" => status,
        "ttl" => 60_000,
        "createdAt" => timestamp,
        "lastUpdatedAt" => timestamp,
        "pollInterval" => 100
      }
    end

    loop = fn loop ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        line ->
          request = JSON.decode!(line)

          case request["method"] do
            "initialize" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => "2025-11-25",
                  "capabilities" => %{
                    "tools" => %{},
                    "tasks" => %{"requests" => %{"tools" => %{"call" => %{}}}}
                  },
                  "serverInfo" => %{"name" => "task-progress", "version" => "1.0.0"}
                }
              })

            "tools/list" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "tools" => [
                    %{
                      "name" => "background",
                      "inputSchema" => %{"type" => "object"},
                      "execution" => %{"taskSupport" => "required"}
                    }
                  ]
                }
              })

            "tools/call" ->
              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{"task" => task.("working")}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => %{
                  "progressToken" => "retained-progress",
                  "progress" => 1,
                  "total" => 3
                }
              })

              # Totals are advisory and may be revised.
              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => %{
                  "progressToken" => "retained-progress",
                  "progress" => 2,
                  "total" => 4
                }
              })

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => %{"progressToken" => "retained-progress", "progress" => 4}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => %{"progressToken" => "retained-progress", "progress" => 2}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => %{"progressToken" => "unknown-progress", "progress" => 9}
              })

            "ping" ->
              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/tasks/status",
                "params" => task.("completed")
              })

              write.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})

            _other ->
              :ok
          end

          loop.(loop)
      end
    end

    loop.(loop)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp run_env_probe(environment) do
    transport = %{
      command: "/usr/bin/env",
      args: [],
      env: environment,
      port: nil
    }

    assert {:ok, %{port: port}} =
             FastestMCP.Client.Transport.Stdio.open(transport, self(), [])

    collect_port_output(port, [])
  end

  defp collect_port_output(port, output) do
    receive do
      {^port, {:data, bytes}} -> collect_port_output(port, [bytes | output])
      {^port, {:exit_status, 0}} -> output |> Enum.reverse() |> IO.iodata_to_binary()
      {^port, {:exit_status, status}} -> flunk("env probe exited with #{status}")
    after
      5_000 -> flunk("env probe timed out")
    end
  end

  defp wait_for_descendants(marker, count, attempts \\ 300)

  defp wait_for_descendants(marker, count, attempts) when attempts > 0 do
    pids = descendant_pids(marker)

    if length(pids) >= count do
      Enum.take(pids, count)
    else
      Process.sleep(20)
      wait_for_descendants(marker, count, attempts - 1)
    end
  end

  defp wait_for_descendants(_marker, count, 0),
    do: flunk("stdio server did not report #{count} descendant processes")

  defp descendant_pids(marker) do
    case File.read(marker) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)

      {:error, :enoent} ->
        []
    end
  end

  defp wait_for_stdio_generation(client_pid, generation, attempts \\ 300)

  defp wait_for_stdio_generation(client_pid, generation, attempts) when attempts > 0 do
    state = :sys.get_state(client_pid)

    if state.transport.generation >= generation and
         FastestMCP.Client.Transport.connected?(state.transport) do
      :ok
    else
      Process.sleep(20)
      wait_for_stdio_generation(client_pid, generation, attempts - 1)
    end
  end

  defp wait_for_stdio_generation(_client_pid, generation, 0),
    do: flunk("stdio transport did not reach generation #{generation}")

  defp wait_until_dead(pid, attempts \\ 300)

  defp wait_until_dead(pid, attempts) when attempts > 0 do
    if StdioProcess.alive?(pid) do
      Process.sleep(20)
      wait_until_dead(pid, attempts - 1)
    else
      :ok
    end
  end

  defp wait_until_dead(pid, 0), do: flunk("stdio descendant #{pid} is still alive")

  defp kill_if_alive(pid) do
    if StdioProcess.alive?(pid) do
      kill = System.find_executable("kill")
      if kill, do: System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
