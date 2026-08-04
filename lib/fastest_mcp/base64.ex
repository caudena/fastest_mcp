defmodule FastestMCP.Base64 do
  @moduledoc false

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    match?({:ok, _decoded}, Base.decode64(value)) or
      match?({:ok, _decoded}, Base.decode64(value, padding: false))
  end

  def valid?(_value), do: false
end
