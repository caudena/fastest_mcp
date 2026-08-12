defmodule FastestMCP.StdioWireIntegrityTest do
  use ExUnit.Case, async: false

  defmodule UnknownStdoutLoggerHandler do
    def adding_handler(config), do: {:ok, config}
    def removing_handler(_config), do: :ok
    def changing_config(_operation, _old_config, new_config), do: {:ok, new_config}
    def log(_event, _config), do: :ok
  end

  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StdioAdapter

  @io_marker "fastest-mcp-stdio-handler-io"
  @child_io_marker "fastest-mcp-stdio-child-io"
  @log_marker "fastest-mcp-stdio-handler-log"
  @task_io_marker "fastest-mcp-stdio-task-io"
  @startup_io_marker "fastest-mcp-stdio-startup-io"
  @startup_log_marker "fastest-mcp-stdio-startup-log"

  test "real stdio subprocess reserves stdout for serialized JSON-RPC lines" do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "fastest-mcp-stdio-#{System.unique_integer([:positive])}.stderr"
      )

    port = start_stdio_server(stderr_path)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      File.rm(stderr_path)
    end)

    send_envelope(port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => Protocol.current_version(),
        "capabilities" => %{},
        "clientInfo" => %{"name" => "wire-integrity", "version" => "1.0.0"}
      }
    })

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"protocolVersion" => version}
           } = receive_envelope(port)

    assert version == Protocol.current_version()

    send_envelope(port, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    })

    send_envelope(port, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "noisy", "arguments" => %{"ok" => true}}
    })

    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => result} = receive_envelope(port)
    assert result["structuredContent"] == %{"ok" => true}

    assert_eventually(fn ->
      case File.read(stderr_path) do
        {:ok, stderr} ->
          String.contains?(stderr, @io_marker) and
            String.contains?(stderr, @child_io_marker) and
            String.contains?(stderr, @log_marker) and
            String.contains?(stderr, @startup_io_marker) and
            String.contains?(stderr, @startup_log_marker)

        {:error, _reason} ->
          false
      end
    end)

    send_raw(port, "{not-json}\n")
    assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32_700}} = receive_envelope(port)

    request_ids = Enum.to_list(100..199)

    Enum.each(request_ids, fn id ->
      send_envelope(port, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "ping",
        "params" => %{}
      })
    end)

    responses = Enum.map(request_ids, fn _id -> receive_envelope(port, 5_000) end)

    assert responses
           |> Enum.map(& &1["id"])
           |> Enum.sort() == request_ids

    assert Enum.all?(responses, fn response ->
             response["jsonrpc"] == "2.0" and response["result"] == %{}
           end)

    send_envelope(port, %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "noisy_task", "arguments" => %{}, "task" => %{}}
    })

    assert %{"id" => 3, "result" => %{"task" => %{"taskId" => task_id}}} =
             receive_until_id(port, 3)

    assert is_binary(task_id)

    assert_eventually(fn ->
      case File.read(stderr_path) do
        {:ok, stderr} -> String.contains?(stderr, @task_io_marker)
        {:error, _reason} -> false
      end
    end)

    send_envelope(port, %{"jsonrpc" => "2.0", "id" => 4, "method" => "ping", "params" => %{}})
    assert %{"id" => 4, "result" => %{}} = receive_until_id(port, 4)
  end

  test "stdio restores logger and runtime supervisor output routing after EOF" do
    server_name = "stdio-routing-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert {:ok, logger_before} = :logger.get_handler_config(:default)

    supervisors = [
      runtime.stream_task_supervisor,
      runtime.call_supervisor,
      runtime.task_supervisor
    ]

    group_leaders_before = Map.new(supervisors, &{&1, process_group_leader(&1)})

    assert :ok = Stdio.serve(server_name, [], :stdio)

    assert {:ok, logger_after} = :logger.get_handler_config(:default)
    assert logger_after == logger_before

    assert Map.new(supervisors, &{&1, process_group_leader(&1)}) == group_leaders_before
  end

  test "stdio startup fails closed when an active stdout Logger handler is unsupported" do
    assert {:ok, original} = :logger.get_handler_config(:default)

    on_exit(fn ->
      _ = :logger.remove_handler(:default)

      :ok =
        :logger.add_handler(
          :default,
          original.module,
          Map.drop(original, [:id, :module])
        )
    end)

    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, UnknownStdoutLoggerHandler, %{
        config: %{type: :standard_io}
      })

    assert_raise ArgumentError,
                 ~r/cannot start stdio transport safely.*UnknownStdoutLoggerHandler.*standard_error/s,
                 fn ->
                   Stdio.serve("stdio-logger-isolation", [], :stdio)
                 end

    assert {:ok, %{module: UnknownStdoutLoggerHandler, config: %{type: :standard_io}}} =
             :logger.get_handler_config(:default)
  end

  test "an abnormal serving-process death restores PID-backed stdout routing and stops its owned server" do
    server_name = "stdio-owned-lease-#{System.unique_integer([:positive])}"
    connection_id = make_ref()
    session_id = StdioAdapter.connection_session_id(connection_id)
    {:ok, wire_io} = StringIO.open("")
    assert {:ok, logger_before} = :logger.get_handler_config(:default)
    assert logger_before.config.type == :standard_io

    serve_pid =
      spawn_stdio_server(
        FastestMCP.server(server_name),
        wire_io,
        connection_id
      )

    serve_monitor = Process.monitor(serve_pid)

    on_exit(fn ->
      if Process.alive?(serve_pid), do: Process.exit(serve_pid, :kill)
      _ = FastestMCP.stop_server(server_name)
    end)

    assert_eventually(fn -> response_written?(wire_io, 1) end)
    assert {:ok, _session} = Registry.lookup_session(server_name, session_id)
    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)

    Process.exit(serve_pid, :kill)
    assert_receive {:DOWN, ^serve_monitor, :process, ^serve_pid, :killed}, 1_000

    assert_eventually(fn ->
      :logger.get_handler_config(:default) == {:ok, logger_before} and
        Registry.lookup_server(server_name) == {:error, :not_found} and
        Registry.lookup_session(server_name, session_id) == {:error, :not_found}
    end)
  end

  test "an abnormal death during lifespan startup aborts the exact owned runtime and restores routing" do
    server_name = "stdio-startup-lease-#{System.unique_integer([:positive])}"
    test_pid = self()
    connection_id = make_ref()
    server_supervisor = Process.whereis(FastestMCP.ServerSupervisor)
    server_supervisor_group_leader = process_group_leader(server_supervisor)
    assert {:ok, logger_before} = :logger.get_handler_config(:default)
    {:ok, wire_io} = StringIO.open("")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_lifespan(fn _server ->
        send(test_pid, {:stdio_blocked_lifespan, self()})

        receive do
          :finish_stdio_blocked_lifespan -> %{}
        end
      end)

    serve_pid = spawn_stdio_server(server, wire_io, connection_id)
    serve_monitor = Process.monitor(serve_pid)

    on_exit(fn ->
      if Process.alive?(serve_pid), do: Process.exit(serve_pid, :kill)
      _ = FastestMCP.stop_server(server_name)
    end)

    assert_receive {:stdio_blocked_lifespan, runtime_pid}, 1_000
    assert Process.alive?(runtime_pid)
    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)

    Process.exit(serve_pid, :kill)
    assert_receive {:DOWN, ^serve_monitor, :process, ^serve_pid, :killed}, 1_000

    assert_eventually(fn ->
      not Process.alive?(runtime_pid) and
        :logger.get_handler_config(:default) == {:ok, logger_before} and
        Registry.lookup_server(server_name) == {:error, :not_found} and
        process_group_leader(server_supervisor) == server_supervisor_group_leader
    end)
  end

  test "an abnormal serving-process death closes its session and restores an existing runtime" do
    server_name = "stdio-existing-lease-#{System.unique_integer([:positive])}"
    connection_id = make_ref()
    session_id = StdioAdapter.connection_session_id(connection_id)
    assert {:ok, server_pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert {:ok, logger_before} = :logger.get_handler_config(:default)
    assert logger_before.config.type == :standard_io
    {:ok, wire_io} = StringIO.open("")

    supervisors = [
      runtime.stream_task_supervisor,
      runtime.call_supervisor,
      runtime.task_supervisor
    ]

    group_leaders_before = Map.new(supervisors, &{&1, process_group_leader(&1)})
    serve_pid = spawn_stdio_server(server_name, wire_io, connection_id)
    serve_monitor = Process.monitor(serve_pid)

    on_exit(fn ->
      if Process.alive?(serve_pid), do: Process.exit(serve_pid, :kill)
      _ = FastestMCP.stop_server(server_name)
    end)

    assert_eventually(fn -> response_written?(wire_io, 1) end)
    assert {:ok, _session} = Registry.lookup_session(server_name, session_id)
    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)

    Process.exit(serve_pid, :kill)
    assert_receive {:DOWN, ^serve_monitor, :process, ^serve_pid, :killed}, 1_000

    assert_eventually(fn ->
      :logger.get_handler_config(:default) == {:ok, logger_before} and
        Registry.lookup_session(server_name, session_id) == {:error, :not_found} and
        Registry.lookup_server(server_name) == {:ok, server_pid} and
        Map.new(supervisors, &{&1, process_group_leader(&1)}) == group_leaders_before
    end)
  end

  defp start_stdio_server(stderr_path) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    shell = System.find_executable("sh") || flunk("sh executable not found on PATH")
    server_name = "stdio-wire-#{System.unique_integer([:positive])}"

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)
    require Logger

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_lifespan(fn _server ->
        IO.puts(#{inspect(@startup_io_marker)})
        Logger.warning(#{inspect(@startup_log_marker)})
        %{}
      end)
      |> FastestMCP.add_tool("noisy", fn arguments, _context ->
        IO.puts(#{inspect(@io_marker)})
        Logger.warning(#{inspect(@log_marker)})

        parent = self()

        spawn(fn ->
          IO.puts(#{inspect(@child_io_marker)})
          send(parent, :child_io_complete)
        end)

        receive do
          :child_io_complete -> arguments
        after
          1_000 -> raise "child IO process did not finish"
        end
      end)
      |> FastestMCP.add_tool(
        "noisy_task",
        fn _arguments, _context ->
          IO.puts(#{inspect(@task_io_marker)})
          %{done: true}
        end,
        task: true
      )

    FastestMCP.Transport.Stdio.serve(server)
    """

    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    shell_script = ~S'''
    stderr_path="$1"
    shift
    exec "$@" 2>"$stderr_path"
    '''

    Port.open(
      {:spawn_executable, shell},
      [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        args:
          ["-c", shell_script, "fastest-mcp-stdio", stderr_path, elixir] ++
            code_paths ++ ["-e", code]
      ]
    )
  end

  defp spawn_stdio_server(server_or_name, wire_io, connection_id) do
    input =
      Stream.concat(
        [initialize_line()],
        Stream.repeatedly(fn ->
          receive do
            :stdio_test_eof -> ""
          end
        end)
      )

    spawn(fn ->
      true = Process.group_leader(self(), wire_io)
      Stdio.serve(server_or_name, input, wire_io, connection_id: connection_id)
    end)
  end

  defp initialize_line do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => Protocol.current_version(),
        "capabilities" => %{},
        "clientInfo" => %{"name" => "cleanup-lease", "version" => "1.0.0"}
      }
    }) <> "\n"
  end

  defp response_written?(wire_io, id) do
    {_input, output} = StringIO.contents(wire_io)
    String.contains?(output, ~s("id":#{id}))
  end

  defp send_envelope(port, envelope), do: send_raw(port, JSON.encode!(envelope) <> "\n")

  defp send_raw(port, data) do
    assert Port.command(port, data)
    :ok
  end

  defp receive_envelope(port, timeout \\ 2_000) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case JSON.decode(line) do
          {:ok, envelope} ->
            envelope

          {:error, reason} ->
            flunk("stdio stdout contained a non-JSON line #{inspect(line)}: #{inspect(reason)}")
        end

      {^port, {:data, {:noeol, line}}} ->
        flunk("stdio stdout emitted an overlong or unterminated line: #{inspect(line)}")

      {^port, {:exit_status, status}} ->
        flunk("stdio subprocess exited with status #{status}")
    after
      timeout -> flunk("timed out waiting for stdio JSON-RPC output")
    end
  end

  defp receive_until_id(port, id, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_until_id(port, id, deadline)
  end

  defp do_receive_until_id(port, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case receive_envelope(port, remaining) do
      %{"id" => ^id} = envelope -> envelope
      _other -> do_receive_until_id(port, id, deadline)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp process_group_leader(pid) do
    assert {:group_leader, group_leader} = Process.info(pid, :group_leader)
    group_leader
  end
end
