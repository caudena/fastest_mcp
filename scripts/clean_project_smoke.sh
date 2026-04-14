#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
project_dir="$tmp_dir/docs_smoke"

cleanup() {
  rm -rf "$tmp_dir"
}

trap cleanup EXIT

mix new --sup "$project_dir" --module DocsSmoke >/dev/null
cd "$project_dir"

cat > mix.exs <<EOF
defmodule DocsSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :docs_smoke,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {DocsSmoke.Application, []}
    ]
  end

  defp deps do
    [
      {:fastest_mcp, path: "$(printf '%s' "$repo_root")"}
    ]
  end
end
EOF

cat > lib/docs_smoke/application.ex <<'EOF'
defmodule DocsSmoke.Application do
  use Application

  def start(_type, _args) do
    children = [
      DocsSmoke.MCPServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DocsSmoke.Supervisor)
  end
end
EOF

cat > lib/docs_smoke/mcp_server.ex <<'EOF'
defmodule DocsSmoke.MCPServer do
  use FastestMCP.ServerModule

  alias FastestMCP.Context

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
    |> FastestMCP.add_tool("visit", fn _arguments, ctx ->
      visits = Context.get_session_state(ctx, :visits, 0) + 1
      :ok = Context.put_session_state(ctx, :visits, visits)
      %{visits: visits}
    end)
  end
end
EOF

mix deps.get >/dev/null
mix run -e '
result = FastestMCP.call_tool(DocsSmoke.MCPServer, "sum", %{"a" => 20, "b" => 22})

unless result == 42 do
  raise "expected onboarding example to return 42, got: #{inspect(result)}"
end
'
