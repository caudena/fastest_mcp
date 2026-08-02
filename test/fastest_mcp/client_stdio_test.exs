defmodule FastestMCP.ClientStdioTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Error
  alias FastestMCP.Protocol

  test "connected client initializes and calls tools over stdio" do
    server_name = "client-stdio-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      case Client.connect(
             {:stdio, elixir, stdio_server_args(server_name)},
             client_info: %{"name" => "client-stdio-test", "version" => "1.0.0"}
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
    assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools(client)
    assert %{"message" => "hi"} = Client.call_tool(client, "echo", %{"message" => "hi"})
  end

  test "connected client authenticates protected stdio servers" do
    server_name = "client-stdio-auth-" <> Integer.to_string(System.unique_integer([:positive]))
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      case Client.connect(
             {:stdio, elixir, protected_stdio_server_args(server_name)},
             access_token: "dev-token"
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

    assert %{"sub" => "local-client"} = Client.call_tool(client, "whoami", %{})
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
               Client.connect({:stdio, elixir, stdio_server_args(server_name)}, max_in_flight: 2)
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
    assert %{"message" => "hi"} = Client.call_tool(client, "echo", %{"message" => "hi"})
  end

  test "stdio client routes notifications without consuming the matching response" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    test_pid = self()

    client =
      Client.connect!(
        {:stdio, elixir, interleaved_stdio_server_args()},
        notification_handler: fn message -> send(test_pid, {:stdio_notification, message}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:stdio_notification,
                    %{"method" => "notifications/message", "params" => %{"data" => "ready"}}}

    assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools(client)

    assert_receive {:stdio_notification,
                    %{"method" => "notifications/message", "params" => %{"data" => "listing"}}}
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

    {:ok, _pid} = FastestMCP.start_server(server)
    FastestMCP.Transport.Stdio.serve(#{inspect(server_name)})
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

    {:ok, _pid} = FastestMCP.start_server(server)
    FastestMCP.Transport.Stdio.serve(#{inspect(server_name)})
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

    {:ok, _pid} = FastestMCP.start_server(server)
    FastestMCP.Transport.Stdio.serve(#{inspect(server_name)})
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
                "params" => %{"data" => "ready"}
              })

              write.(%{
                "jsonrpc" => "2.0",
                "id" => request["id"],
                "result" => %{
                  "protocolVersion" => FastestMCP.Protocol.current_version(),
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "interleaved", "version" => "1.0.0"}
                }
              })

            "tools/list" ->
              write.(%{"jsonrpc" => "2.0", "id" => "stale", "result" => %{}})

              write.(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/message",
                "params" => %{"data" => "listing"}
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
end
