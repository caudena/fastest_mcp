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
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.StdioAdapter

  @doc "Dispatches one request through this transport."
  def dispatch(server_name, request, opts \\ []) do
    case StdioAdapter.decode(request) do
      {:ok, normalized_request} ->
        try do
          result = Engine.dispatch!(server_name, normalized_request, opts)
          StdioAdapter.encode_success(normalized_request, result)
        rescue
          error in Error ->
            StdioAdapter.encode_error(
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
    Enum.each(input_device, fn line ->
      response =
        line
        |> String.trim()
        |> decode_request()
        |> then(&dispatch(server_name, &1, opts))
        |> Jason.encode!()

      IO.binwrite(output_device, response)
      IO.binwrite(output_device, "\n")
    end)
  end

  defp decode_request(""), do: %{"method" => "noop"}
  defp decode_request(line), do: Jason.decode!(line)

  defp fetch_server(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, %{server: server}} -> server
      _other -> nil
    end
  end
end
