defmodule FastestMCP.Client.OAuth.TokenStore.Memory do
  @moduledoc """
  Per-client in-memory OAuth token store.

  This is the default store and is intentionally non-durable. Applications
  that need tokens across restarts should configure their own encrypted
  `FastestMCP.Client.OAuth.TokenStore` implementation.
  """

  use Agent

  @behaviour FastestMCP.Client.OAuth.TokenStore

  @doc false
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end)

  @impl true
  def get(pid, key), do: Agent.get(pid, &Map.get(&1, key))

  @impl true
  def put(pid, key, token_set) do
    Agent.update(pid, &Map.put(&1, key, token_set))
  end

  @impl true
  def delete(pid, key) do
    Agent.update(pid, &Map.delete(&1, key))
  end
end
