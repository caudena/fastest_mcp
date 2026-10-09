defmodule FastestMCP.TTLStore do
  @moduledoc false
  # Public key/value table whose entries expire `ttl_ms` after they are
  # written. The creating process owns the table; reads skip expired entries
  # and `sweep/1` deletes them.

  defstruct [:table, :ttl_ms]

  def new(ttl_ms) do
    %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public, read_concurrency: true]),
      ttl_ms: ttl_ms
    }
  end

  def put(%__MODULE__{table: table, ttl_ms: ttl_ms}, key, value) do
    :ets.insert(table, {key, value, expires_at(ttl_ms)})
    :ok
  end

  def get(%__MODULE__{table: table}, key) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] -> if expired?(expires_at), do: :error, else: {:ok, value}
      [] -> :error
    end
  end

  def sweep(%__MODULE__{table: table}) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(table, [
      {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
    ])

    :ok
  end

  defp expires_at(:infinity), do: :infinity
  defp expires_at(ttl_ms), do: System.monotonic_time(:millisecond) + ttl_ms

  defp expired?(:infinity), do: false
  defp expired?(expires_at), do: expires_at < System.monotonic_time(:millisecond)
end
