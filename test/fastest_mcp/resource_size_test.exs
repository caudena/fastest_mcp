defmodule FastestMCP.ResourceSizeTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Component
  alias FastestMCP.Transport.Serializer

  test "resource size is compiled and preserved through metadata serialization" do
    server =
      FastestMCP.server("resource-size")
      |> FastestMCP.add_resource(
        "file:///tmp/report.json",
        fn _arguments, _context -> %{} end,
        size: 12_345
      )

    [resource] = server.resources

    assert resource.size == 12_345
    assert Component.metadata(resource).size == 12_345
    assert Serializer.resource_metadata(Component.metadata(resource))["size"] == 12_345
  end

  test "resource size must be a non-negative integer when declared" do
    assert_raise ArgumentError, fn ->
      FastestMCP.server("negative-resource-size")
      |> FastestMCP.add_resource("file:///tmp/report.json", fn _arguments, _context -> %{} end,
        size: -1
      )
    end

    assert_raise ArgumentError, fn ->
      FastestMCP.server("invalid-resource-size")
      |> FastestMCP.add_resource("file:///tmp/report.json", fn _arguments, _context -> %{} end,
        size: "123"
      )
    end
  end
end
