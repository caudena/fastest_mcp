defmodule FastestMCP.Client.Transport.StreamableHTTP do
  @moduledoc false
  # Each request opens its own HTTP exchange in `FastestMCP.Client.HTTP`, so
  # the transport itself holds no connection.

  @behaviour FastestMCP.Client.Transport

  @impl true
  def open(transport, _owner), do: {:ok, transport}

  @impl true
  def connected?(_transport), do: true

  @impl true
  def send_line(_transport, _line, _auth_input), do: {:error, :request_required}

  @impl true
  def close(_transport), do: :ok
end
