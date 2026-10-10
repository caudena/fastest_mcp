#!/usr/bin/env bash
# Builds a fresh Mix project from the Getting Started server (the files in
# test/support/docs/my_app/, which docs/getting-started.md shows verbatim) and
# checks the in-process results that step 3 of the tutorial prints.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
project_dir="$tmp_dir/my_app"

cleanup() {
  rm -rf "$tmp_dir"
}

trap cleanup EXIT

mix new --sup "$project_dir" --module MyApp >/dev/null
cd "$project_dir"

cat > mix.exs <<EOF
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyApp.Application, []}
    ]
  end

  defp deps do
    [
      {:fastest_mcp, path: "$(printf '%s' "$repo_root")"}
    ]
  end
end
EOF

cp "$repo_root/test/support/docs/my_app/notes.ex" lib/my_app/notes.ex
cp "$repo_root/test/support/docs/my_app/mcp_server.ex" lib/my_app/mcp_server.ex

cat > lib/my_app/application.ex <<'EOF'
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Notes,
      MyApp.MCPServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
EOF

mix deps.get >/dev/null
mix run -e '
note =
  FastestMCP.call_tool!(MyApp.MCPServer, "add_note", %{
    "title" => "Release",
    "body" => "Ship the notes server on Friday"
  })

expected = %{id: "1", title: "Release", body: "Ship the notes server on Friday"}
unless note == expected, do: raise("add_note returned #{inspect(note)}")

found = FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "friday"})
unless found == %{notes: [expected]}, do: raise("search_notes returned #{inspect(found)}")

read = FastestMCP.read_resource!(MyApp.MCPServer, "notes://1")
unless read == expected, do: raise("notes://1 returned #{inspect(read)}")

IO.puts("Getting Started smoke test passed")
'
