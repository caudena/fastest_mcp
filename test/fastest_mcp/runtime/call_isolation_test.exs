defmodule FastestMCP.Runtime.CallIsolationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Error

  test "one crashing tool does not poison the server runtime" do
    server_name = "isolation-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("explode", fn _args, _ctx -> raise "boom" end)
    |> FastestMCP.add_tool("echo", fn %{"message" => message}, _ctx ->
      %{"message" => message}
    end)
    |> start_server!()

    assert_raise Error, ~r/explode/, fn ->
      FastestMCP.call_tool!(server_name, "explode", %{})
    end

    assert %{"message" => "still alive"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "still alive"})
  end
end
