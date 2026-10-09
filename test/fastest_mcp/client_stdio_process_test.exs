defmodule FastestMCP.Client.StdioProcessTest do
  use FastestMCP.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.StdioProcess
  alias FastestMCP.Error
  alias FastestMCP.Test.ClientProbe
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

  # A stage ends as soon as the child is gone, so long stage timeouts only
  # matter on a loaded machine. A stage a test expects to elapse in full (EOF
  # for children that ignore standard input) gets a short timeout instead.
  @shutdown_opts [
    eof_timeout_ms: 50,
    term_timeout_ms: 5_000,
    kill_timeout_ms: 5_000,
    poll_interval_ms: 5
  ]

  setup_all do
    if StdioProcess.signal_supported?() and System.find_executable("cc") do
      {launcher, directory} = StdioProcessGroupFixture.build!()
      on_exit(fn -> File.rm_rf!(directory) end)
      {:ok, launcher: launcher}
    else
      {:ok, launcher: nil}
    end
  end

  test "closing the port lets an EOF-aware child exit" do
    if StdioProcess.signal_supported?() do
      {port, pid} = open_shell("read _line || exit 0")
      on_exit(fn -> kill_if_alive(pid) end)

      assert {:ok, :eof} =
               StdioProcess.shutdown(port, Keyword.put(@shutdown_opts, :eof_timeout_ms, 5_000))

      refute StdioProcess.alive?(pid)
    end
  end

  test "shutdown terminates a child that does not consume standard input" do
    if StdioProcess.signal_supported?() do
      {port, pid} = open_shell("exec sleep 60")
      on_exit(fn -> kill_if_alive(pid) end)

      assert {:ok, stage} = StdioProcess.shutdown(port, @shutdown_opts)
      assert stage in [:eof, :term]
      refute StdioProcess.alive?(pid)
    end
  end

  test "shutdown kills a child that ignores TERM" do
    if StdioProcess.signal_supported?() do
      {port, pid} = open_shell("trap '' TERM; echo ready; exec sleep 60")
      on_exit(fn -> kill_if_alive(pid) end)
      # TERM must not arrive before the shell ignores it.
      assert_receive {^port, {:data, "ready\n"}}, 10_000

      assert {:ok, :kill} =
               StdioProcess.shutdown(port, Keyword.put(@shutdown_opts, :term_timeout_ms, 100))

      refute StdioProcess.alive?(pid)
    end
  end

  test "shutdown tolerates a child that has already exited" do
    if StdioProcess.signal_supported?() do
      {port, pid} = open_shell("exit 0")
      on_exit(fn -> kill_if_alive(pid) end)
      wait_until_dead(pid)

      assert {:ok, stage} = StdioProcess.shutdown(port, @shutdown_opts)
      assert stage in [:already_closed, :eof]
    end
  end

  test "process-group shutdown terminates descendants", %{launcher: launcher} do
    if launcher do
      {_port, handle, child_pid} = open_group_shell(launcher)

      on_exit(fn ->
        _ = StdioProcess.shutdown(handle, @shutdown_opts)
        kill_if_alive(child_pid)
      end)

      assert StdioProcess.alive?(handle)
      assert StdioProcess.alive?(child_pid)
      assert {:ok, stage} = StdioProcess.shutdown(handle, @shutdown_opts)
      assert stage in [:term, :kill]
      wait_until_dead(child_pid)
      refute StdioProcess.alive?(handle)
    end
  end

  test "a stale generation cannot shut down a process group", %{launcher: launcher} do
    if launcher do
      {_port, handle, child_pid} = open_group_shell(launcher)

      on_exit(fn ->
        _ = StdioProcess.shutdown(handle, @shutdown_opts)
        kill_if_alive(child_pid)
      end)

      assert {:error, :stale_generation} =
               StdioProcess.shutdown(handle,
                 expected_generation: handle.generation + 1,
                 eof_timeout_ms: 0,
                 term_timeout_ms: 0,
                 kill_timeout_ms: 0
               )

      assert StdioProcess.alive?(handle)
      assert StdioProcess.alive?(child_pid)
    end
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

  test "process-group stdio restart and disconnect terminate spawned descendants", %{
    launcher: launcher
  } do
    if launcher do
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

          Client.disconnect!(client)
        end

        marker
        |> descendant_pids()
        |> Enum.each(&kill_if_alive/1)

        File.rm(marker)
      end)

      [first_descendant] = wait_for_descendants(marker, 1)
      initial_generation = ClientProbe.transport(client).generation
      assert StdioProcess.alive?(first_descendant)

      crash =
        Client.request_async!(client, "tools/call", %{
          "name" => "crash",
          "arguments" => %{}
        })

      assert_raise Error, fn -> Client.Request.await!(crash, 3_000) end
      wait_for_stdio_generation(client.pid, initial_generation + 1)

      [^first_descendant, second_descendant] = wait_for_descendants(marker, 2)
      wait_until_dead(first_descendant)
      assert StdioProcess.alive?(second_descendant)

      original_adapter = ClientProbe.transport(client).adapter

      :sys.replace_state(client.pid, fn state ->
        put_in(state.transport.adapter, UnprovenCloseTransport)
      end)

      assert {:error, %FastestMCP.Error{details: %{reason: :process_still_alive}}} =
               Client.disconnect(client)

      assert Process.alive?(client.pid)
      assert StdioProcess.alive?(second_descendant)

      :sys.replace_state(client.pid, fn state ->
        put_in(state.transport.adapter, original_adapter)
      end)

      assert :ok = Client.disconnect!(client)
      wait_until_dead(second_descendant)
    end
  end

  defp open_shell(script) do
    shell = System.find_executable("sh") || flunk("sh is required for stdio process tests")

    port =
      Port.open(
        {:spawn_executable, shell},
        [:binary, :exit_status, :use_stdio, args: ["-c", script]]
      )

    {port, StdioProcess.os_pid(port) || flunk("stdio child did not expose an OS pid")}
  end

  defp open_group_shell(launcher) do
    shell = System.find_executable("sh") || flunk("sh is required for stdio process tests")

    port =
      Port.open(
        {:spawn_executable, launcher},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["cwd", "device", "minor", "inode", shell, "-c", "sleep 60 & echo $!; wait"]
        ]
      )

    assert {:ok, handle} = StdioProcess.capture(port, 7, :process_group)

    child_pid =
      receive do
        {^port, {:data, bytes}} -> bytes |> String.trim() |> String.to_integer()
      after
        # A loaded machine can take seconds to start the shell.
        10_000 -> flunk("descendant pid was not reported")
      end

    {port, handle, child_pid}
  end

  defp wait_until_dead(pid), do: assert_eventually(fn -> not StdioProcess.alive?(pid) end, 6_000)

  defp kill_if_alive(pid) do
    if StdioProcess.alive?(pid) do
      kill = System.find_executable("kill")
      if kill, do: System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
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

  defp wait_for_descendants(marker, count) do
    assert_eventually(
      fn ->
        pids = descendant_pids(marker)
        length(pids) >= count and Enum.take(pids, count)
      end,
      6_000
    )
  end

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

  defp wait_for_stdio_generation(client_pid, generation) do
    assert_eventually(
      fn ->
        transport = ClientProbe.transport(client_pid)
        transport.generation >= generation and FastestMCP.Client.Transport.connected?(transport)
      end,
      6_000
    )
  end
end
