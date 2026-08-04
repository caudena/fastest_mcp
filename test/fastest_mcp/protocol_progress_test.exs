defmodule FastestMCP.Protocol.ProgressTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol.Progress

  test "requires numeric strictly increasing progress" do
    assert {:ok, nil} = Progress.validate_update(0.5, nil, :absent, nil)
    assert {:error, :invalid_progress} = Progress.validate_update("1", nil, :absent, nil)
    assert {:error, :non_increasing_progress} = Progress.validate_update(1, 1, :absent, nil)
  end

  test "accepts changing totals without treating them as a progress bound" do
    assert {:ok, 10} = Progress.validate_update(1, nil, {:provided, 10}, nil)
    assert {:ok, 2} = Progress.validate_update(3, 1, {:provided, 2}, 10)
    assert {:ok, 2} = Progress.validate_update(4, 3, :absent, 2)
    assert {:error, :invalid_total} = Progress.validate_update(5, 4, {:provided, "5"}, 2)
  end

  test "extracts atom and string totals without coercion" do
    assert Progress.total(%{}) == :absent
    assert Progress.total(%{"total" => 2.5}) == {:provided, 2.5}
    assert Progress.total(%{total: 3}) == {:provided, 3}
  end
end
