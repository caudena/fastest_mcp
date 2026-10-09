defmodule FastestMCP.Client.Transport.StreamableHTTP do
  @moduledoc false
  # Each request opens its own HTTP exchange in `FastestMCP.Client.HTTP`, so
  # the transport itself holds no connection.

  @behaviour FastestMCP.Client.Transport

  @impl true
  def open(transport, _owner, _opts), do: {:ok, transport}

  @impl true
  def connected?(_transport), do: true

  @impl true
  def send_envelope(_transport, _envelope), do: {:error, :request_required}

  @impl true
  def close(_transport), do: :ok
end
