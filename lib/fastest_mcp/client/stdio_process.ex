defmodule FastestMCP.Client.StdioProcess do
  @moduledoc false

  @default_eof_timeout_ms 1_000
  @default_term_timeout_ms 1_000
  @default_kill_timeout_ms 1_000
  @default_poll_interval_ms 10

  @type shutdown_stage :: :already_closed | :eof | :term | :kill

  @spec shutdown(port(), keyword()) ::
          {:ok, shutdown_stage()} | {:error, :unsupported_signals | :process_still_alive}
  def shutdown(port, opts \\ []) when is_port(port) and is_list(opts) do
    eof_timeout_ms = timeout_option!(opts, :eof_timeout_ms, @default_eof_timeout_ms)
    term_timeout_ms = timeout_option!(opts, :term_timeout_ms, @default_term_timeout_ms)
    kill_timeout_ms = timeout_option!(opts, :kill_timeout_ms, @default_kill_timeout_ms)
    poll_interval_ms = positive_option!(opts, :poll_interval_ms, @default_poll_interval_ms)
    os_pid = os_pid(port)
    open? = Port.info(port) != nil

    close_port(port)

    cond do
      not open? or is_nil(os_pid) ->
        {:ok, :already_closed}

      not signal_supported?() ->
        {:error, :unsupported_signals}

      await_exit(os_pid, eof_timeout_ms, poll_interval_ms) ->
        {:ok, :eof}

      signal(os_pid, "-TERM") != :ok ->
        if alive?(os_pid), do: {:error, :process_still_alive}, else: {:ok, :term}

      await_exit(os_pid, term_timeout_ms, poll_interval_ms) ->
        {:ok, :term}

      signal(os_pid, "-KILL") != :ok ->
        if alive?(os_pid), do: {:error, :process_still_alive}, else: {:ok, :kill}

      await_exit(os_pid, kill_timeout_ms, poll_interval_ms) ->
        {:ok, :kill}

      true ->
        {:error, :process_still_alive}
    end
  end

  @doc false
  def os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  @doc false
  def alive?(pid) when is_integer(pid) and pid > 0 do
    case kill_command() do
      nil ->
        false

      command ->
        case System.cmd(command, ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> true
          {output, _status} -> String.contains?(output, "Operation not permitted")
        end
    end
  rescue
    _error -> false
  end

  def alive?(_pid), do: false

  @doc false
  def signal_supported?, do: match?({:unix, _name}, :os.type()) and not is_nil(kill_command())

  defp await_exit(pid, timeout_ms, poll_interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_exit(pid, deadline, poll_interval_ms)
  end

  defp do_await_exit(pid, deadline, poll_interval_ms) do
    cond do
      not alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)
        Process.sleep(min(poll_interval_ms, max(remaining_ms, 0)))
        do_await_exit(pid, deadline, poll_interval_ms)
    end
  end

  defp signal(pid, signal) do
    case kill_command() do
      nil ->
        {:error, :unsupported}

      command ->
        case System.cmd(command, [signal, Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, _status} -> {:error, :signal_failed}
        end
    end
  rescue
    _error -> {:error, :signal_failed}
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp kill_command do
    System.find_executable("kill")
  end

  defp timeout_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value -> raise ArgumentError, "#{key} must be a non-negative integer, got #{inspect(value)}"
    end
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got #{inspect(value)}"
    end
  end
end
