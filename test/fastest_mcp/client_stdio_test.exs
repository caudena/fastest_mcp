defmodule FastestMCP.ClientStdioTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Test.ClientProbe

  alias FastestMCP.Client
  alias FastestMCP.Error
  alias FastestMCP.Protocol

  test "stdio replacement environments reject ambiguous or unbounded entries before spawn" do
    target = {:stdio, "/usr/bin/env", []}

    assert_raise ArgumentError, "stdio env contains duplicate variable names", fn ->
      Client.connect(target, env: [{"TOKEN", "one"}, {"TOKEN", "two"}])
    end

    for environment <- [
          [{"BAD-NAME", "value"}],
          [{"TOKEN", false}],
          [{"TOKEN", nil}]
        ] do
      assert_raise ArgumentError,
                   "stdio env must be a map or keyword list of scalar values",
                   fn -> Client.connect(target, env: environment) end
    end

    assert_raise ArgumentError, "stdio env exceeds the bounded environment size", fn ->
      Client.connect(target, env: %{"TOKEN" => String.duplicate("x", 65_536)})
    end
  end

  test "stdio bounds an unterminated response frame" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    # The frame stays unterminated until the client closes standard input.
    script = """
    IO.read(:stdio, :line)
    IO.binwrite(:stdio, String.duplicate("x", 4_097))
    IO.read(:stdio, :eof)
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
      connect!(
        {:stdio, elixir, stdio_server_args(server_name)},
        client_info: %{"name" => "client-stdio-test", "version" => "1.0.0"},
        env: %{
          "ELIXIR_ERL_OPTIONS" => "+fnu",
          "FASTMCP_CHILD_TEST" => "from-client",
          "PATH" => System.fetch_env!("PATH")
        }
      )

    assert Client.connected?(client)
    assert Client.info!(client).protocol_version == Protocol.current_version()
    assert %{items: tools, next_cursor: nil} = Client.list_tools!(client)
    assert Enum.sort(Enum.map(tools, & &1["name"])) == ["child_env", "echo"]

    assert %{raw: %{"structuredContent" => %{"message" => "hi"}}} =
             Client.call_tool!(client, "echo", %{"message" => "hi"})

    assert %{raw: %{"structuredContent" => %{"value" => "from-client"}}} =
             Client.call_tool!(client, "child_env", %{})
  end

  test "connected client authenticates protected stdio servers" do
    server_name = "client-stdio-auth-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      connect!(
        {:stdio, elixir, protected_stdio_server_args(server_name)},
        access_token: "dev-token",
        legacy_stdio_auth_metadata: true
      )

    assert %{raw: %{"structuredContent" => %{"sub" => "local-client"}}} =
             Client.call_tool!(client, "whoami", %{})
  end

  test "stdio authentication metadata is omitted unless the legacy option is explicit" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      connect!(
        {:stdio, elixir, auth_metadata_probe_stdio_server_args()},
        protocol_version: "2025-11-25",
        access_token: "must-not-be-written-to-json-rpc"
      )

    assert get_in(Client.info!(client).initialize_result, ["serverInfo", "name"]) == "clean-wire"
  end

  test "stdio clients reject max_in_flight values above one" do
    server_name =
      "client-stdio-capacity-" <> Integer.to_string(System.unique_integer([:positive]))

    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    assert_raise ArgumentError, "legacy stdio max_in_flight must be 1, got: 2", fn ->
      Client.connect({:stdio, elixir, stdio_server_args(server_name)},
        protocol_version: "2025-11-25",
        max_in_flight: 2
      )
    end
  end

  test "stdio request timeouts do not crash the client" do
    server_name = "client-stdio-timeout-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client = connect!({:stdio, elixir, slow_stdio_server_args(server_name)})

    error =
      assert_raise Error, fn ->
        Client.call_tool!(client, "slow", %{}, timeout_ms: 10)
      end

    assert error.code == :timeout, inspect(error)

    assert Client.connected?(client)

    assert %{raw: %{"structuredContent" => %{"message" => "hi"}}} =
             Client.call_tool!(client, "echo", %{"message" => "hi"})
  end

  test "automatic stdio negotiation falls back on the same live process after a non-modern error" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client = connect!({:stdio, elixir, legacy_fallback_stdio_server_args()})

    assert %Client.Info{
             protocol_version: "2025-11-25",
             initialize_result: %{"serverInfo" => %{"name" => "same-process"}}
           } = Client.info!(client)

    assert %{items: [%{"name" => "fallback-ok"}]} = Client.list_tools!(client)
  end

  test "stdio client routes notifications without consuming the matching response" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      connect!(
        {:stdio, elixir, interleaved_stdio_server_args()},
        protocol_version: "2025-11-25",
        notification_handler: fn message -> send(test_pid, {:stdio_notification, message}) end
      )

    assert_receive {:stdio_notification,
                    %{
                      "method" => "notifications/message",
                      "params" => %{"level" => "info", "data" => "ready"}
                    }}

    assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools!(client)

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
      connect!(
        {:stdio, elixir, modern_concurrent_stdio_server_args(server_name)},
        protocol_version: "2026-07-28",
        max_in_flight: 4,
        notification_handler: fn message -> send(test_pid, {:global_notification, message}) end
      )

    listener =
      Client.listen!(
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
      Client.request_async!(client, "tools/call", %{
        "name" => "slow",
        "arguments" => %{}
      })

    fast =
      Client.request_async!(client, "tools/call", %{
        "name" => "fast",
        "arguments" => %{}
      })

    assert %{"structuredContent" => %{"name" => "fast"}} = Client.Request.await!(fast, 2_000)
    assert %{"structuredContent" => %{"name" => "slow"}} = Client.Request.await!(slow, 2_000)

    cancelled =
      Client.request_async!(client, "tools/call", %{
        "name" => "slow",
        "arguments" => %{}
      })

    cancelled_id = cancelled.request_id
    assert :ok = Client.Request.cancel!(cancelled, "ordinary request cancellation")

    refute_receive {:global_notification,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{"requestId" => ^cancelled_id}
                    }},
                   300

    assert %{items: tools} = Client.list_tools!(client)
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

    assert :ok = Client.Request.cancel!(listener, "test complete")

    assert %{"structuredContent" => %{"name" => "fast"}} =
             client
             |> Client.request_async!("tools/call", %{
               "name" => "fast",
               "arguments" => %{}
             })
             |> Client.Request.await!(2_000)

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

    assert %{items: tools} = Client.list_tools!(client)
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
      connect!(
        {:stdio, elixir, restartable_modern_stdio_server_args(server_name)},
        protocol_version: "2026-07-28",
        stdio_restart: [max_attempts: 3, retry_ms: 10, max_retry_ms: 50]
      )

    assert %{raw: %{"structuredContent" => %{"name" => "fast"}}} =
             Client.call_tool!(client, "fast", %{})

    catalog_generation = ClientProbe.tool_catalog(client).generation

    listener =
      Client.listen!(
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
      Client.request_async!(client, "tools/call", %{
        "name" => "crash",
        "arguments" => %{}
      })

    assert_raise Error, fn -> Client.Request.await!(crash, 3_000) end

    assert_receive {:restart_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => second_subscription_id
                        }
                      }
                    }},
                   15_000

    refute second_subscription_id == first_subscription_id
    assert first_subscription_id == listener.request_id

    restarted_catalog = ClientProbe.tool_catalog(client)
    assert restarted_catalog.generation > catalog_generation
    refute restarted_catalog.ready?

    assert %{raw: %{"structuredContent" => %{"name" => "fast"}}} =
             Client.call_tool!(client, "fast", %{})

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
    assert :ok = Client.Request.cancel!(listener, "test complete")
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
      connect!(
        {:stdio, elixir, exhausting_modern_stdio_server_args(server_name, marker)},
        protocol_version: "2026-07-28",
        stdio_restart: [max_attempts: 2, retry_ms: 10, max_retry_ms: 20]
      )

    client_ref = Process.monitor(client.pid)
    on_exit(fn -> File.rm(marker) end)

    listener =
      Client.listen!(client, %{"resourceSubscriptions" => ["status://restart"]},
        on_notification: fn message -> send(test_pid, {:exhaustion_notification, message}) end
      )

    assert_receive {:exhaustion_notification,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   2_000

    crash =
      Client.request_async!(client, "tools/call", %{
        "name" => "crash",
        "arguments" => %{}
      })

    assert_raise Error, fn -> Client.Request.await!(crash, 3_000) end
    assert_raise Error, fn -> Client.Request.await!(listener, 15_000) end

    assert_receive {:DOWN, ^client_ref, :process, _pid, :normal}, 15_000
    refute Client.connected?(client)
  end

  test "task progress retains token ownership, stays monotonic, and cleans up at terminal" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      connect!(
        {:stdio, elixir, task_progress_stdio_server_args()},
        protocol_version: "2025-11-25",
        progress_handler: fn params -> send(test_pid, {:task_progress, params}) end
      )

    assert %FastestMCP.Client.Task{task_id: "remote-progress-task"} =
             Client.call_tool_task!(client, "background", %{},
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
        Client.request_async!(client, "ping", %{
          "_meta" => %{"progressToken" => "retained-progress"}
        })
      end

    assert error.code == :invalid_params

    # The probe emits a terminal task notification before answering ping.
    assert %{} = Client.ping!(client)

    request =
      Client.request_async!(client, "ping", %{
        "_meta" => %{"progressToken" => "retained-progress"}
      })

    assert %{} = Client.Request.await!(request)
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
end
