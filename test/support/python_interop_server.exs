server =
  FastestMCP.server("elixir-interop")
  |> FastestMCP.add_tool("echo", fn arguments, _ -> arguments end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer"}},
      "required" => ["value"]
    }
  )
  |> FastestMCP.add_tool("empty", fn _, _ -> %{} end)
  |> FastestMCP.add_resource("data://interop/value", fn _, _ -> "hello" end)

FastestMCP.Transport.Stdio.serve(server)
