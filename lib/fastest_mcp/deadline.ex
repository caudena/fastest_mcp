defmodule FastestMCP.Deadline do
  @moduledoc false
  # An absolute monotonic deadline in milliseconds, or :infinity. Option
  # values are validated where they are read; a zero timeout is a deadline
  # that has already passed.
  alias FastestMCP.Error

  def new(:infinity), do: :infinity

  def new(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  def new(other),
    do: raise(ArgumentError, "timeout must be non-negative or :infinity, got: #{inspect(other)}")

  # The `:deadline` in `opts`, else `:timeout_ms` (or `default`) from now.
  def from_options(opts, default),
    do: Keyword.get_lazy(opts, :deadline, fn -> new(Keyword.get(opts, :timeout_ms, default)) end)

  def cap(deadline, timeout) do
    case {deadline, new(timeout)} do
      {:infinity, local} -> local
      {overall, :infinity} -> overall
      {overall, local} -> min(overall, local)
    end
  end

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def check(deadline, operation) do
    case remaining(deadline) do
      0 -> {:error, Error.timeout(operation)}
      remaining -> {:ok, remaining}
    end
  end
end
