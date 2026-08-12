defmodule FastestMCP.Client.StdioProcessTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client.StdioProcess

  @shutdown_opts [
    eof_timeout_ms: 50,
    term_timeout_ms: 100,
    kill_timeout_ms: 100,
    poll_interval_ms: 5
  ]

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

  defp open_shell(script) do
    shell = System.find_executable("sh") || flunk("sh is required for stdio process tests")

    port =
      Port.open(
        {:spawn_executable, shell},
        [:binary, :exit_status, :use_stdio, args: ["-c", script]]
      )

    {port, StdioProcess.os_pid(port) || flunk("stdio child did not expose an OS pid")}
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
