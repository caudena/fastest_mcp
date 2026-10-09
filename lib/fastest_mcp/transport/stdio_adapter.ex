defmodule FastestMCP.Transport.StdioAdapter do
  @moduledoc false
  # Decodes the JSON-RPC messages of MCP's newline-delimited stdio transport.
  # Every message of a connection belongs to the connection's session.

  alias FastestMCP.Error
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  def decode(message, opts \\ []) when is_list(opts) do
    connection_id = Keyword.get(opts, :connection_id)
    session_id = connection_session_id(connection_id || self())

    with {:ok, decoded} <- JSONRPC.decode(message),
         {:ok, request} <- Request.from_jsonrpc(decoded, message) do
      {:ok,
       %{
         request
         | transport: :stdio,
           session_id: session_id,
           session_id_provided?: true,
           protocol_version: request.protocol_version || initialize_version(decoded),
           auth_input:
             Map.merge(Map.new(Keyword.get(opts, :auth_input, %{})), wire_auth(decoded)),
           request_metadata:
             Map.merge(request.request_metadata, %{
               method: request.method,
               session_id: session_id,
               connection_id: connection_id
             })
       }}
    end
  end

  def connection_session_id(connection_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(connection_id))
    "stdio-" <> Base.url_encode64(digest, padding: false)
  end

  # The response to a message that could not be decoded.
  def decode_error(%Error{} = error) do
    unless JSONRPC.notification_error?(error), do: JSONRPC.error(nil, error)
  end

  # Legacy negotiation names the version in the initialize params.
  defp initialize_version({:request, "initialize", params, _id}), do: params["protocolVersion"]
  defp initialize_version(_decoded), do: nil

  # A stdio client authenticates through `_meta.fastestmcp.auth`.
  defp wire_auth({:request, _method, params, _id}) do
    case get_in(params, ["_meta", "fastestmcp", "auth"]) do
      %{} = auth -> auth
      _other -> %{}
    end
  end

  defp wire_auth(_decoded), do: %{}
end
