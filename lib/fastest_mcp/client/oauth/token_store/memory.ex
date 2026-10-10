defmodule FastestMCP.Client.OAuth.TokenStore.Memory do
  @moduledoc """
  Per-client in-memory OAuth token store.

  This is the default store and is intentionally non-durable. Applications
  that need tokens across restarts should configure their own encrypted
  `FastestMCP.Client.OAuth.TokenStore` implementation.
  """

  use GenServer

  @behaviour FastestMCP.Client.OAuth.TokenStore

  @doc false
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{})

  @impl FastestMCP.Client.OAuth.TokenStore
  def get(pid, key), do: GenServer.call(pid, {:get, key})

  @impl FastestMCP.Client.OAuth.TokenStore
  def put(pid, key, token_set), do: GenServer.call(pid, {:put, key, token_set})

  @impl FastestMCP.Client.OAuth.TokenStore
  def delete(pid, key), do: GenServer.call(pid, {:delete, key})

  @impl GenServer
  def init(tokens), do: {:ok, tokens}

  @impl GenServer
  def handle_call({:get, key}, _from, tokens), do: {:reply, Map.get(tokens, key), tokens}

  def handle_call({:put, key, token_set}, _from, tokens),
    do: {:reply, :ok, Map.put(tokens, key, token_set)}

  def handle_call({:delete, key}, _from, tokens), do: {:reply, :ok, Map.delete(tokens, key)}

  # Crash reports leave out the tokens.
  @impl GenServer
  defdelegate format_status(status), to: FastestMCP.Client.Redaction
end
