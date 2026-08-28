defmodule FastestMCP.Client.StdioProcessTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client.StdioProcess
  alias FastestMCP.Test.StdioProcessGroupFixture

  @shutdown_opts [
    eof_timeout_ms: 50,
    term_timeout_ms: 100,
    kill_timeout_ms: 100,
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

      assert {:ok, :eof} = StdioProcess.shutdown(port, @shutdown_opts)
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
      {port, pid} = open_shell("trap '' TERM; exec sleep 60")
      on_exit(fn -> kill_if_alive(pid) end)

      assert {:ok, :kill} = StdioProcess.shutdown(port, @shutdown_opts)
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
        2_000 -> flunk("descendant pid was not reported")
      end

    {port, handle, child_pid}
  end

  defp wait_until_dead(pid, attempts \\ 100)

  defp wait_until_dead(pid, attempts) when attempts > 0 do
    if StdioProcess.alive?(pid) do
      Process.sleep(5)
      wait_until_dead(pid, attempts - 1)
    else
      :ok
    end
  end

  defp wait_until_dead(_pid, 0), do: flunk("stdio child did not exit")

  defp kill_if_alive(pid) do
    if StdioProcess.alive?(pid) do
      kill = System.find_executable("kill")
      if kill, do: System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
