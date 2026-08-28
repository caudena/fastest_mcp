defmodule FastestMCP.Client.StdioProcess do
  @moduledoc false

  defmodule Handle do
    @moduledoc false

    @enforce_keys [:port, :os_pid, :generation, :signal_scope]
    defstruct [:port, :os_pid, :generation, :signal_scope]

    @type t :: %__MODULE__{
            port: port(),
            os_pid: pos_integer(),
            generation: non_neg_integer(),
            signal_scope: :process | :process_group
          }
  end

  @default_eof_timeout_ms 1_000
  @default_term_timeout_ms 1_000
  @default_kill_timeout_ms 1_000
  @default_poll_interval_ms 10

  @type shutdown_stage :: :already_closed | :eof | :term | :kill

  @spec capture(port(), non_neg_integer(), :process | :process_group) ::
          {:ok, Handle.t()} | {:error, :missing_os_pid}
  def capture(port, generation, signal_scope)
      when is_port(port) and is_integer(generation) and generation >= 0 and
             signal_scope in [:process, :process_group] do
    case os_pid(port) do
      pid when is_integer(pid) ->
        {:ok,
         %Handle{
           port: port,
           os_pid: pid,
           generation: generation,
           signal_scope: signal_scope
         }}

      nil ->
        {:error, :missing_os_pid}
    end
  end

  @spec shutdown(port() | Handle.t(), keyword()) ::
          {:ok, shutdown_stage()}
          | {:error, :unsupported_signals | :process_still_alive | :stale_generation}
  def shutdown(process, opts \\ [])

  def shutdown(port, opts) when is_port(port) and is_list(opts) do
    case capture(port, 0, :process) do
      {:ok, handle} -> shutdown(handle, opts)
      {:error, :missing_os_pid} -> close_without_pid(port)
    end
  end

  def shutdown(%Handle{} = handle, opts) when is_list(opts) do
    eof_timeout_ms = timeout_option!(opts, :eof_timeout_ms, @default_eof_timeout_ms)
    term_timeout_ms = timeout_option!(opts, :term_timeout_ms, @default_term_timeout_ms)
    kill_timeout_ms = timeout_option!(opts, :kill_timeout_ms, @default_kill_timeout_ms)
    poll_interval_ms = positive_option!(opts, :poll_interval_ms, @default_poll_interval_ms)
    expected_generation = generation_option!(opts, handle.generation)

    if expected_generation != handle.generation do
      {:error, :stale_generation}
    else
      close_port(handle.port)
      shutdown_target(handle, eof_timeout_ms, term_timeout_ms, kill_timeout_ms, poll_interval_ms)
    end
  end

  defp shutdown_target(
         handle,
         eof_timeout_ms,
         term_timeout_ms,
         kill_timeout_ms,
         poll_interval_ms
       ) do
    target = signal_target(handle)

    cond do
      not signal_supported?() ->
        {:error, :unsupported_signals}

      await_exit(target, eof_timeout_ms, poll_interval_ms) ->
        {:ok, :eof}

      signal(target, "-TERM") != :ok ->
        if target_alive?(target), do: {:error, :process_still_alive}, else: {:ok, :term}

      await_exit(target, term_timeout_ms, poll_interval_ms) ->
        {:ok, :term}

      signal(target, "-KILL") != :ok ->
        if target_alive?(target), do: {:error, :process_still_alive}, else: {:ok, :kill}

      await_exit(target, kill_timeout_ms, poll_interval_ms) ->
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
        case System.cmd(command, ["-0", "--", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> true
          {output, _status} -> String.contains?(output, "Operation not permitted")
        end
    end
  rescue
    _error -> false
  end

  @doc false
  def alive?(%Handle{} = handle), do: target_alive?(signal_target(handle))

  def alive?(_pid), do: false

  @doc false
  def signal_supported?, do: match?({:unix, _name}, :os.type()) and not is_nil(kill_command())

  defp await_exit(target, timeout_ms, poll_interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_exit(target, deadline, poll_interval_ms)
  end

  defp do_await_exit(target, deadline, poll_interval_ms) do
    cond do
      not target_alive?(target) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)
        Process.sleep(min(poll_interval_ms, max(remaining_ms, 0)))
        do_await_exit(target, deadline, poll_interval_ms)
    end
  end

  defp signal(target, signal) do
    case kill_command() do
      nil ->
        {:error, :unsupported}

      command ->
        case System.cmd(command, [signal, "--", signal_argument(target)], stderr_to_stdout: true) do
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

  defp close_without_pid(port) do
    close_port(port)
    {:ok, :already_closed}
  end

  defp signal_target(%Handle{signal_scope: :process, os_pid: pid}), do: {:process, pid}

  defp signal_target(%Handle{signal_scope: :process_group, os_pid: pid}),
    do: {:process_group, pid}

  defp signal_argument({:process, pid}), do: Integer.to_string(pid)
  defp signal_argument({:process_group, pid}), do: "-#{pid}"

  defp target_alive?({:process, pid}), do: alive?(pid)

  defp target_alive?({:process_group, pid}) do
    case kill_command() do
      nil ->
        false

      command ->
        case System.cmd(command, ["-0", "--", "-#{pid}"], stderr_to_stdout: true) do
          {_output, 0} -> true
          {output, _status} -> String.contains?(output, "Operation not permitted")
        end
    end
  rescue
    _error -> false
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

  defp generation_option!(opts, default) do
    case Keyword.get(opts, :expected_generation, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError,
              "expected_generation must be a non-negative integer, got #{inspect(value)}"
    end
  end
end
