defmodule FastestMCP.Client.OAuth.Error do
  @moduledoc """
  Redacted error returned by the MCP OAuth client coordinator.

  The struct deliberately carries the stage and a sanitized reason only. Raw
  authorization codes, access tokens, refresh tokens, client secrets, and PKCE
  verifiers must never be placed in this value.
  """

  defexception [:stage, :reason, message: "OAuth authorization failed"]

  @type stage ::
          :configuration
          | :protected_resource_discovery
          | :authorization_server_discovery
          | :client_registration
          | :authorization
          | :token_exchange
          | :token_refresh

  @type t :: %__MODULE__{stage: stage(), reason: term(), message: String.t()}

  @impl true
  def exception(opts) do
    stage = Keyword.fetch!(opts, :stage)
    reason = opts |> Keyword.fetch!(:reason) |> sanitize()

    %__MODULE__{
      stage: stage,
      reason: reason,
      message: "OAuth #{label(stage)} failed: #{reason_label(reason)}"
    }
  end

  # Only atoms and HTTP statuses describe a failure without echoing a
  # response body or a credential.
  defp sanitize({:http_status, status, _body}), do: {:http_status, status}
  defp sanitize({:http_status, _status} = reason), do: reason
  defp sanitize(reason) when is_atom(reason), do: reason
  defp sanitize(_reason), do: :request_failed

  defp label(value), do: value |> to_string() |> String.replace("_", " ")

  defp reason_label({:http_status, status}) when is_integer(status), do: "HTTP #{status}"
  defp reason_label(reason) when is_atom(reason), do: label(reason)
  defp reason_label(_reason), do: "request rejected"
end
