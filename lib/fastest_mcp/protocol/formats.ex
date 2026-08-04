defmodule FastestMCP.Protocol.Formats do
  @moduledoc false

  @behaviour JSV.FormatValidator

  alias FastestMCP.Base64
  alias FastestMCP.Components.ResourceTemplate.Matcher

  @impl true
  def supported_formats, do: ["byte", "uri-template"]

  @impl true
  def applies_to_type?(_format, value), do: is_binary(value)

  @impl true
  def validate_cast("byte", value) do
    if Base64.valid?(value), do: {:ok, value}, else: {:error, :invalid_base64}
  end

  def validate_cast("uri-template", value) do
    case Matcher.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
