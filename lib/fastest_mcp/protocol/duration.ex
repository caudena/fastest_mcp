defmodule FastestMCP.Protocol.Duration do
  @moduledoc false

  @doc false
  @spec positive_milliseconds(term()) :: {:ok, pos_integer()} | {:error, :invalid_duration}
  def positive_milliseconds(value) when is_number(value) and value > 0 do
    {:ok, ceil(value)}
  rescue
    ArithmeticError -> {:error, :invalid_duration}
  end

  def positive_milliseconds(_value), do: {:error, :invalid_duration}

  @doc false
  @spec positive_milliseconds!(term(), String.t()) :: pos_integer()
  def positive_milliseconds!(value, label) do
    case positive_milliseconds(value) do
      {:ok, milliseconds} ->
        milliseconds

      {:error, :invalid_duration} ->
        raise ArgumentError, "#{label} must be a positive number, got #{inspect(value)}"
    end
  end
end
