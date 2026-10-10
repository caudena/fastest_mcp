defmodule FastestMCP.Client.Transport do
  @moduledoc false

  alias FastestMCP.Error

  @type state :: map()

  @callback open(state(), pid()) :: {:ok, state()} | {:error, term()}
  @callback connected?(state()) :: boolean()
  @callback send_line(state(), binary(), map()) :: :ok | {:error, term()}
  @callback close(state()) :: :ok | {:error, term()}

  @spec open(state(), pid()) :: {:ok, state()} | {:error, term()}
  def open(%{adapter: adapter} = transport, owner), do: adapter.open(transport, owner)

  @spec connected?(state()) :: boolean()
  def connected?(%{adapter: adapter} = transport), do: adapter.connected?(transport)

  # Writes one message to a stdio or in-process peer, as a JSON line. An
  # in-process server receives `auth_input` beside it, as Elixir terms.
  @spec write(state(), map(), map()) :: :ok | {:error, Error.t()}
  def write(%{adapter: adapter, type: type} = transport, envelope, auth_input \\ %{}) do
    with {:ok, line} <- encode(envelope) do
      case adapter.send_line(transport, line, auth_input) do
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
  end

  defp encode(envelope) do
    {:ok, JSON.encode!(envelope)}
  rescue
    error ->
      {:error,
       %Error{
         code: :internal_error,
         message: "the message cannot be encoded as JSON: " <> Exception.message(error)
       }}
  end

  @spec close(state()) :: :ok | {:error, term()}
  def close(%{adapter: adapter} = transport), do: adapter.close(transport)

  def name(:stdio), do: "stdio"
  def name(:in_process), do: "in-process"
end
