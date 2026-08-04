defmodule FastestMCP.ResourceURITest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol.URI, as: ProtocolURI

  test "accepts absolute resource URI families used by MCP" do
    for uri <- [
          "https://example.test/resource",
          "file:///tmp/report.txt",
          "urn:example:report",
          "config://release",
          "data:text/plain,hello"
        ] do
      assert ProtocolURI.valid?(uri)

      assert %{uri: ^uri} =
               FastestMCP.server("resource-uri-valid")
               |> FastestMCP.add_resource(uri, fn _arguments, _context -> "ok" end)
               |> Map.fetch!(:resources)
               |> List.last()
    end
  end

  test "rejects relative, unescaped, and malformed-percent resource URIs at registration" do
    for uri <- ["relative/path", "not a uri", "https://example.test/a b", "urn:example:%ZZ"] do
      refute ProtocolURI.valid?(uri)

      assert_raise ArgumentError, ~r/resource URI must be an absolute RFC 3986 URI/, fn ->
        FastestMCP.server("resource-uri-invalid")
        |> FastestMCP.add_resource(uri, fn _arguments, _context -> "ok" end)
      end
    end
  end
end
