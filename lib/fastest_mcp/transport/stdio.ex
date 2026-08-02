defmodule FastestMCP.Transport.Stdio do
  @moduledoc """
  JSON-line stdio transport backed by the shared transport engine.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by the shared transport engine,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.ServerRuntime
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.StdioAdapter

  @doc "Dispatches one request through this transport."
  def dispatch(server_name, request, opts \\ []) do
    with {:ok, request} <- decode_input(request) do
      do_dispatch(server_name, request, opts)
    else
      {:error, %Error{} = error} -> StdioAdapter.encode_error(error)
    end
  end

  defp do_dispatch(server_name, request, opts) do
    case StdioAdapter.decode(request, opts) do
      {:ok, normalized_request} ->
        try do
          result = Engine.dispatch!(server_name, normalized_request, opts)
          StdioAdapter.encode_success(normalized_request, result)
        rescue
          error in Error ->
            StdioAdapter.encode_error(
              normalized_request,
              ErrorExposure.public_error(
                error,
                server: fetch_server(server_name),
                request: normalized_request
              )
            )
        end

      {:error, %Error{} = error} ->
        StdioAdapter.encode_error(error)
    end
  end

  @doc "Runs the transport server loop."
  def serve(
        server_name,
        input_device \\ IO.binstream(:stdio, :line),
        output_device \\ :stdio,
        opts \\ []
      ) do
    opts = Keyword.put_new_lazy(opts, :connection_id, &make_ref/0)

    try do
      Enum.each(input_device, fn line ->
        case String.trim(line) do
          "" ->
            :ok

          encoded ->
            case dispatch(server_name, encoded, opts) do
              :no_response ->
                :ok

              response ->
                IO.binwrite(output_device, JSON.encode!(response))
                IO.binwrite(output_device, "\n")
            end
        end
      end)
    after
      close_connection_session(server_name, Keyword.fetch!(opts, :connection_id))
    end
  end

  defp close_connection_session(server_name, connection_id) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      _ =
        SessionSupervisor.terminate_session(
          runtime.session_supervisor,
          server_name,
          StdioAdapter.connection_session_id(connection_id)
        )

      :ok
    else
      _other -> :ok
    end
  end

  defp decode_input(request) when is_map(request), do: {:ok, request}

  defp decode_input(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, JSONRPC.parse_error("invalid JSON", %{reason: inspect(reason)})}
    end
  end

  defp decode_input(_request) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "stdio request must be a JSON-RPC object",
       details: %{jsonrpc_code: -32_600}
     }}
  end

  defp fetch_server(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, %{server: server}} -> server
      _other -> nil
    end
  end
end
