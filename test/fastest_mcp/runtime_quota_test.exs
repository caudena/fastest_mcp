defmodule FastestMCP.RuntimeQuotaTest do
  use ExUnit.Case, async: true

  alias FastestMCP.RuntimeQuota

  test "bounds aggregate use across owners and releases on owner death" do
    {:ok, quota} =
      start_supervised(
        {RuntimeQuota, max_pending_requests: 2, max_active_requests: 1, max_sse_replay_bytes: 10}
      )

    owner_a = spawn(fn -> Process.sleep(:infinity) end)
    owner_b = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = RuntimeQuota.claim(quota, owner_a, :pending_requests)
    assert :ok = RuntimeQuota.claim(quota, owner_b, :pending_requests)
    assert {:error, :overloaded} = RuntimeQuota.claim(quota, owner_a, :pending_requests)

    assert :ok = RuntimeQuota.claim(quota, owner_a, :active_requests)
    assert {:error, :overloaded} = RuntimeQuota.claim(quota, owner_b, :active_requests)

    assert :ok = RuntimeQuota.resize(quota, owner_a, :sse_replay_bytes, 7)
    assert {:error, :overloaded} = RuntimeQuota.resize(quota, owner_b, :sse_replay_bytes, 4)
    assert :ok = RuntimeQuota.resize(quota, owner_b, :sse_replay_bytes, 3)

    Process.exit(owner_a, :kill)

    assert eventually(fn ->
             RuntimeQuota.snapshot(quota).usage == %{
               pending_requests: 1,
               active_requests: 0,
               sse_replay_bytes: 3
             }
           end)

    assert :ok = RuntimeQuota.claim(quota, owner_b, :active_requests)
    assert :ok = RuntimeQuota.resize(quota, owner_b, :sse_replay_bytes, 10)
  end

  test "release and resize are idempotently bounded at zero" do
    {:ok, quota} = start_supervised({RuntimeQuota, []})
    owner = self()

    assert :ok = RuntimeQuota.release(quota, owner, :pending_requests, 100)
    assert :ok = RuntimeQuota.resize(quota, owner, :sse_replay_bytes, 0)
    assert RuntimeQuota.snapshot(quota).owners == %{}
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
