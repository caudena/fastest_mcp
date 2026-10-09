defmodule FastestMCP.Client.Transport do
  @moduledoc false

  alias FastestMCP.Error

  @type state :: map()

  @callback open(state(), pid(), keyword()) :: {:ok, state()} | {:error, term()}
  @callback connected?(state()) :: boolean()
  @callback send_envelope(state(), map()) :: :ok | {:error, term()}
  @callback close(state()) :: :ok | {:error, term()}

  @spec open(state(), pid(), keyword()) :: {:ok, state()} | {:error, term()}
  def open(%{adapter: adapter} = transport, owner, opts) do
    adapter.open(transport, owner, opts)
  end

  @spec connected?(state()) :: boolean()
  def connected?(%{adapter: adapter} = transport), do: adapter.connected?(transport)

  # Writes one message to a stdio or in-process peer.
  @spec write(state(), map()) :: :ok | {:error, Error.t()}
  def write(%{adapter: adapter, type: type} = transport, envelope) do
    case adapter.send_envelope(transport, envelope) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "#{name(type)} client transport is closed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  @spec close(state()) :: :ok | {:error, term()}
  def close(%{adapter: adapter} = transport), do: adapter.close(transport)

  def name(:stdio), do: "stdio"
  def name(:in_process), do: "in-process"
end
