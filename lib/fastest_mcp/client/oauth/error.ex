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
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      stage: stage,
      reason: reason,
      message: "OAuth #{stage_label(stage)} failed: #{reason_label(reason)}"
    }
  end

  defp stage_label(stage), do: stage |> to_string() |> String.replace("_", " ")

  defp reason_label(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp reason_label({reason, detail}) when is_atom(reason) and is_binary(detail),
    do: reason_label(reason) <> ": " <> detail

  defp reason_label({:http_status, status}) when is_integer(status),
    do: "HTTP #{status}"

  defp reason_label(_reason), do: "request rejected"
end
