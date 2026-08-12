defmodule FastestMCP.Protocol.URI do
  @moduledoc false

  @doc false
  def valid?(value) when is_binary(value) and value != "" do
    match?({:ok, %Elixir.URI{}}, JSV.FormatValidator.Default.validate_cast("uri", value))
  end

  def valid?(_value), do: false

  @doc false
  def validate(value) do
    if valid?(value), do: :ok, else: {:error, :invalid_absolute_uri}
  end

  @doc false
  def validate!(value, label \\ "URI") do
    if valid?(value) do
      value
    else
      raise ArgumentError, "#{label} must be an absolute RFC 3986 URI, got: #{inspect(value)}"
    end
  end
end
