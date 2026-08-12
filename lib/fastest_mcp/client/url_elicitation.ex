defmodule FastestMCP.Client.URLElicitation do
  @moduledoc """
  A server-initiated URL elicitation presented to a connected client.

  FastestMCP never opens or fetches the URL. The application handler is
  responsible for clearly displaying the requesting server and target host and
  collecting user consent before returning `:accept`.
  """

  alias FastestMCP.Error

  @enforce_keys [:elicitation_id, :url, :message]
  defstruct [:elicitation_id, :url, :message, :origin, meta: nil]

  @type t :: %__MODULE__{
          elicitation_id: String.t(),
          url: String.t(),
          message: String.t(),
          origin: String.t() | nil,
          meta: map() | nil
        }

  @doc false
  def parse(%{} = params) do
    with elicitation_id when is_binary(elicitation_id) and elicitation_id != "" <-
           params["elicitationId"],
         url when is_binary(url) and url != "" <- params["url"],
         message when is_binary(message) and message != "" <- params["message"],
         {:ok, uri} <- parse_absolute_uri(url) do
      {:ok,
       %__MODULE__{
         elicitation_id: elicitation_id,
         url: url,
         message: message,
         origin: origin(uri),
         meta: params["_meta"]
       }}
    else
      _other ->
        {:error,
         %Error{
           code: :bad_request,
           message: "invalid URL elicitation request"
         }}
    end
  end

  defp parse_absolute_uri(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _other ->
        :error
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}) when is_binary(host) do
    default_port? =
      (scheme == "https" and port in [nil, 443]) or (scheme == "http" and port in [nil, 80])

    if default_port?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end
end
