defmodule FastestMCP.Deadline do
  @moduledoc false
  alias FastestMCP.Error

  def new(:infinity), do: :infinity

  def new(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  def new(other),
    do: raise(ArgumentError, "timeout must be positive or :infinity, got: #{inspect(other)}")

  def from_options(opts, default),
    do: Keyword.get_lazy(opts, :deadline, fn -> new(Keyword.get(opts, :timeout_ms, default)) end)

  def cap(deadline, timeout) do
    case {deadline, new(timeout)} do
      {:infinity, local} -> local
      {overall, :infinity} -> overall
      {overall, local} -> min(overall, local)
    end
  end

  def request_options(opts, default, operation) do
    timeout = Keyword.get(opts, :timeout_ms, default)
    deadline = opts |> from_options(default) |> cap(timeout)

    opts
    |> Keyword.put(:deadline, deadline)
    |> Keyword.put(:timeout_ms, remaining!(deadline, operation))
  end

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def check(deadline, operation) do
    case remaining(deadline) do
      0 -> {:error, %Error{code: :timeout, message: "#{operation} timed out"}}
      remaining -> {:ok, remaining}
    end
  end

  def remaining!(deadline, operation) do
    case check(deadline, operation) do
      {:ok, remaining} -> remaining
      {:error, error} -> raise error
    end
  end
end
