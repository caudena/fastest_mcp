defmodule FastestMCP.ClientResponseCacheUnitTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Client.ResponseCache

  test "expires entries and updates recency on hits" do
    cache = ResponseCache.new(max_entries: 2, max_item_size: 1_000)
    cache = ResponseCache.put(cache, :first, %{value: 1}, 10, 100)
    cache = ResponseCache.put(cache, :second, %{value: 2}, 100, 100)

    assert {:hit, %{value: 1}, cache} = ResponseCache.get(cache, :first, 105)
    cache = ResponseCache.put(cache, :third, %{value: 3}, 100, 105)

    assert {:miss, cache} = ResponseCache.get(cache, :second, 105)
    assert {:hit, %{value: 1}, cache} = ResponseCache.get(cache, :first, 105)
    assert {:miss, _cache} = ResponseCache.get(cache, :first, 111)
  end

  test "does not store zero ttl or oversized values" do
    cache = ResponseCache.new(max_entries: 2, max_item_size: 8)
    cache = ResponseCache.put(cache, :zero, :value, 0, 0)
    cache = ResponseCache.put(cache, :large, String.duplicate("x", 100), 100, 0)

    assert ResponseCache.size(cache) == 0
  end

  test "disabled caches remain empty" do
    cache = ResponseCache.new(false)
    cache = ResponseCache.put(cache, :key, :value, 100, 0)

    assert {:miss, ^cache} = ResponseCache.get(cache, :key, 1)
    assert ResponseCache.size(cache) == 0
  end

  test "rejects unknown configuration keys" do
    assert_raise ArgumentError, ~r/unknown response_cache options: :maximum/, fn ->
      ResponseCache.new(maximum: 10)
    end
  end
end
