defmodule FastestMCP.Client.Transport.StreamableHTTP do
  @moduledoc false

  @behaviour FastestMCP.Client.Transport

  alias FastestMCP.HTTP

  @impl true
  def open(transport, _owner, _opts), do: {:ok, transport}

  @impl true
  def connected?(_transport), do: true

  @impl true
  def send_envelope(_transport, _envelope), do: {:error, :request_required}

  @impl true
  def close(_transport), do: :ok

  @doc false
  def request(method, url, opts), do: HTTP.request(method, url, opts)

  @doc false
  def stream_request(method, url, opts), do: HTTP.stream_request(method, url, opts)

  @doc false
  def cancel_request(request_ref), do: HTTP.cancel_request(request_ref)
end
