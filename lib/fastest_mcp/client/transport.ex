defmodule FastestMCP.Client.Transport do
  @moduledoc false

  @type state :: map()

  @callback open(state(), pid(), keyword()) :: {:ok, state()} | {:error, term()}
  @callback connected?(state()) :: boolean()
  @callback send_envelope(state(), map()) :: :ok | {:error, term()}
  @callback close(state()) :: :ok | {:error, term()}

  @spec open(state(), pid(), keyword()) :: {:ok, state()} | {:error, term()}
  def open(%{adapter: adapter} = transport, owner, opts \\ []) do
    adapter.open(transport, owner, opts)
  end

  @spec connected?(state()) :: boolean()
  def connected?(%{adapter: adapter} = transport), do: adapter.connected?(transport)

  @spec send_envelope(state(), map()) :: :ok | {:error, term()}
  def send_envelope(%{adapter: adapter} = transport, envelope) do
    adapter.send_envelope(transport, envelope)
  end

  @spec close(state()) :: :ok | {:error, term()}
  def close(%{adapter: adapter} = transport), do: adapter.close(transport)
end
