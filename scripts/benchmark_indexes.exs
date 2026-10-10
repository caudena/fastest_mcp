# Run with: mix run scripts/benchmark_indexes.exs
# Measurements are diagnostic output, not correctness assertions.
alias FastestMCP.ComponentIndex
alias FastestMCP.Client.ToolCatalog

measure = fn count, operation ->
  Enum.each(1..count, fn _ -> operation.() end)
  {elapsed, _} = :timer.tc(fn -> Enum.each(1..count, fn _ -> operation.() end) end)
  Float.round(elapsed / 1_000, 3)
end

for size <- [100, 1_000, 10_000] do
  server_name = "lookup-benchmark-#{size}"

  server =
    Enum.reduce(1..size, FastestMCP.server(server_name), fn index, server ->
      FastestMCP.add_tool(server, "tool_#{index}", fn args, _ctx -> args end)
    end)
    |> FastestMCP.add_tool("echo", fn args, _ctx -> args end, version: "1.0.0")

  {:ok, _pid} = FastestMCP.start_server(server)

  tools =
    for index <- 1..size, do: %{"name" => "tool_#{index}", "inputSchema" => %{"type" => "object"}}

  catalog = ToolCatalog.build(tools, 1, [])

  IO.puts(
    JSON.encode!(%{
      components: size + 1,
      index_300_default_reads_ms:
        measure.(300, fn -> ComponentIndex.candidates(server_name, :tool, "echo") end),
      index_300_exact_reads_ms:
        measure.(300, fn -> ComponentIndex.candidates(server_name, :tool, "echo", "1.0.0") end),
      catalog_tools: size,
      catalog_500_reads_ms: measure.(500, fn -> ToolCatalog.lookup(catalog, "tool_#{size}") end)
    })
  )

  :ok = FastestMCP.stop_server(server_name)
end
