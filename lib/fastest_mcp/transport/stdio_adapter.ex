defmodule FastestMCP.Transport.StdioAdapter do
  @moduledoc """
  JSON-RPC 2.0 adapter for MCP's newline-delimited stdio transport.
  """

  @behaviour FastestMCP.Transport.Adapter

  alias FastestMCP.Error
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  @impl true
  def decode(message), do: decode(message, [])

  @doc "Decodes one JSON-RPC message for a stdio connection."
  def decode(message, opts) when is_list(opts) do
    session_id = connection_session_id(Keyword.get(opts, :connection_id, self()))

    case JSONRPC.decode(message) do
      {:ok, {:request, method, params, request_id}} ->
        with {:ok, {task_request, task_ttl_ms}} <- JSONRPC.task_metadata(params) do
          {:ok,
           %Request{
             method: method,
             transport: :stdio,
             session_id: session_id,
             request_id: request_id,
             protocol: :jsonrpc,
             task_request: task_request,
             task_ttl_ms: task_ttl_ms,
             payload: params,
             request_metadata: %{
               method: method,
               session_id: session_id,
               session_id_provided: true,
               connection_id: Keyword.get(opts, :connection_id),
               jsonrpc_request_id: request_id,
               jsonrpc_envelope: message,
               progress_token: get_in(params, ["_meta", "progressToken"])
             },
             auth_input: request_auth_input(params, opts)
           }}
        end

      {:ok, {:response, request_id, payload}} ->
        {:ok,
         %Request{
           method: "__transport/client_response__",
           transport: :stdio,
           session_id: session_id,
           request_id: request_id,
           protocol: :jsonrpc,
           payload: payload,
           request_metadata: %{
             session_id: session_id,
             session_id_provided: true,
             connection_id: Keyword.get(opts, :connection_id),
             jsonrpc_envelope: message
           },
           auth_input: Map.new(Keyword.get(opts, :auth_input, %{}))
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def encode_success(%Request{request_id: nil}, _payload), do: :no_response
  def encode_success(%Request{} = request, payload), do: JSONRPC.success(request, payload)

  @impl true
  def encode_error(%Error{} = error) do
    if JSONRPC.notification_error?(error), do: :no_response, else: JSONRPC.error(nil, error)
  end

  @doc "Encodes an error for a decoded request."
  def encode_error(%Request{request_id: nil}, %Error{}), do: :no_response
  def encode_error(%Request{} = request, %Error{} = error), do: JSONRPC.error(request, error)

  @doc false
  def connection_session_id(connection_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(connection_id))
    "stdio-" <> Base.url_encode64(digest, padding: false)
  end

  defp request_auth_input(params, opts) do
    wire_auth = get_in(params, ["_meta", "fastestmcp", "auth"])

    case wire_auth do
      %{} = auth -> Map.merge(Map.new(Keyword.get(opts, :auth_input, %{})), auth)
      _other -> Map.new(Keyword.get(opts, :auth_input, %{}))
    end
  end
end
