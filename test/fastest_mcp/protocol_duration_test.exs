defmodule FastestMCP.Protocol.DurationTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol.Duration

  test "rounds positive numeric milliseconds up for runtime timers" do
    assert Duration.positive_milliseconds(1) == {:ok, 1}
    assert Duration.positive_milliseconds(1.01) == {:ok, 2}
    assert Duration.positive_milliseconds(0.01) == {:ok, 1}
  end

  test "rejects non-positive and non-numeric durations" do
    assert Duration.positive_milliseconds(0) == {:error, :invalid_duration}
    assert Duration.positive_milliseconds(-1) == {:error, :invalid_duration}
    assert Duration.positive_milliseconds("1") == {:error, :invalid_duration}
  end
end
