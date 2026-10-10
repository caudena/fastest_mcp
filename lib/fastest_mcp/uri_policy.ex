defmodule FastestMCP.URIPolicy do
  @moduledoc false
  # URI and HTTP auth-parameter rules shared by auth, roots, URL elicitation,
  # resource templates, and the HTTP transport.

  @invalid_percent_encoding ~r/%(?![0-9A-Fa-f]{2})/

  # Whether every `%` starts a percent-encoded octet.
  def valid_percent_encoding?(nil), do: true
  def valid_percent_encoding?(value), do: not Regex.match?(@invalid_percent_encoding, value)

  # RFC 6749 scope-token = 1*( %x21 / %x23-5B / %x5D-7E )
  def scope_token?(value) when is_binary(value) and value != "" do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 == 0x21 or &1 in 0x23..0x5B or &1 in 0x5D..0x7E))
  end

  def scope_token?(_value), do: false

  # Escapes an HTTP quoted-string parameter value; line breaks become spaces.
  def quote_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace(["\r", "\n"], " ")
  end

  # Whether a parsed URI host (IPv6 without brackets) names this machine.
  def loopback_host?(host), do: String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

  def drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  def drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  def drop_default_port(uri), do: uri
end
