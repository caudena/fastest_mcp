defmodule FastestMCP.DocsConfigAssetTest do
  use ExUnit.Case, async: true

  # Regression: ISSUE-001 — generated docs site requested docs_config.js but did not ship it
  # Found by /qa on 2026-04-11
  # Report: .gstack/qa-reports/qa-report-fastest-mcp-docs-local-2026-04-11.md
  test "docs config copies docs_config.js into the generated site root" do
    docs = FastestMCP.MixProject.project()[:docs]

    assert %{"docs/assets" => "."} = Keyword.fetch!(docs, :assets)
  end
end
