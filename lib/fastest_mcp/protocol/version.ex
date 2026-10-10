defmodule FastestMCP.Protocol.Version do
  @moduledoc false
  # The MCP protocol versions, spelled once. The macros expand to literals,
  # so they work in patterns and guards; the module has no dependencies, so
  # importing it adds no compile-time cycle.

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defmacro modern, do: @modern
  defmacro legacy, do: @legacy

  defguard is_modern(version) when version == @modern
  defguard is_legacy(version) when version == @legacy
end
