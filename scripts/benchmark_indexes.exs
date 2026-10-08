# Run with: mix run scripts/benchmark_indexes.exs
# Measurements are diagnostic output, not correctness assertions.
alias FastestMCP.{ComponentCompiler, Registry}
alias FastestMCP.Client.ToolCatalog

target = "lookup-benchmark-target"
unrelated = "lookup-benchmark-unrelated"
tool = ComponentCompiler.compile(:tool, target, "echo", fn args, _ -> args end, version: "1.0.0")
Registry.register_component(target, tool)

measure = fn count, operation ->
  Enum.each(1..count, fn _ -> operation.() end)
  {elapsed, _} = :timer.tc(fn -> Enum.each(1..count, fn _ -> operation.() end) end)
  Float.round(elapsed / 1_000, 3)
end

for size <- [100, 1_000, 10_000] do
  Enum.each(1..size, fn index ->
    Registry.register_component(unrelated, %{tool | name: "tool_#{index}"})
  end)

  tools =
    for index <- 1..size, do: %{"name" => "tool_#{index}", "inputSchema" => %{"type" => "object"}}

  catalog = ToolCatalog.build(tools, 1, [])

  IO.puts(
    JSON.encode!(%{
      unrelated_components: size,
      registry_300_default_reads_ms:
        measure.(300, fn -> Registry.get_component(target, :tool, "echo") end),
      registry_300_exact_reads_ms:
        measure.(300, fn -> Registry.get_component(target, :tool, "echo", version: "1.0.0") end),
      catalog_tools: size,
      catalog_500_reads_ms: measure.(500, fn -> ToolCatalog.lookup(catalog, "tool_#{size}") end)
    })
  )
end
