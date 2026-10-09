defmodule FastestMCP.RuntimeQuotaTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.RuntimeQuota

  test "bounds aggregate use of each resource and frees released capacity" do
    quota = RuntimeQuota.new(pending_requests: 2, active_requests: 1, sse_replay_bytes: 10)

    assert :ok = RuntimeQuota.claim(quota, :pending_requests)
    assert :ok = RuntimeQuota.claim(quota, :pending_requests)
    assert {:error, :overloaded} = RuntimeQuota.claim(quota, :pending_requests)

    assert :ok = RuntimeQuota.claim(quota, :active_requests)
    assert {:error, :overloaded} = RuntimeQuota.claim(quota, :active_requests)

    assert :ok = RuntimeQuota.resize(quota, :sse_replay_bytes, 0, 7)
    assert {:error, :overloaded} = RuntimeQuota.resize(quota, :sse_replay_bytes, 0, 4)
    assert :ok = RuntimeQuota.resize(quota, :sse_replay_bytes, 0, 3)

    assert RuntimeQuota.snapshot(quota) == %{
             pending_requests: 2,
             active_requests: 1,
             sse_replay_bytes: 10
           }

    assert :ok = RuntimeQuota.release(quota, :pending_requests)
    assert :ok = RuntimeQuota.release(quota, :active_requests)
    assert :ok = RuntimeQuota.resize(quota, :sse_replay_bytes, 7, 0)

    assert RuntimeQuota.snapshot(quota) == %{
             pending_requests: 1,
             active_requests: 0,
             sse_replay_bytes: 3
           }

    assert :ok = RuntimeQuota.claim(quota, :active_requests)
    assert :ok = RuntimeQuota.resize(quota, :sse_replay_bytes, 3, 10)
    assert {:error, :overloaded} = RuntimeQuota.claim(quota, :sse_replay_bytes)
  end

  test "concurrent claims never exceed the limit" do
    quota = RuntimeQuota.new(pending_requests: 50, active_requests: 1, sse_replay_bytes: 1)

    claimed =
      1..200
      |> Task.async_stream(fn _ -> RuntimeQuota.claim(quota, :pending_requests) end,
        max_concurrency: 16
      )
      |> Enum.count(&(&1 == {:ok, :ok}))

    assert claimed == 50
    assert RuntimeQuota.snapshot(quota).pending_requests == 50
  end
end
