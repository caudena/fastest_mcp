defmodule FastestMCP.Protocol.VersionTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Protocol
  alias FastestMCP.Transport.Request

  @modern_version "2026-07-28"
  @legacy_version "2025-11-25"

  test "publishes supported versions newest first and derives implementation profiles" do
    assert Protocol.supported_versions() == [@modern_version, @legacy_version]
    assert Protocol.current_version() == @modern_version
    assert FastestMCP.current_protocol_version() == @modern_version
    assert FastestMCP.supported_protocol_versions() == [@modern_version, @legacy_version]

    assert Protocol.supported_version?(@modern_version)
    assert Protocol.supported_version?(@legacy_version)
    refute Protocol.supported_version?("2025-03-26")
    refute Protocol.supported_version?(nil)

    assert Protocol.profile(@modern_version) == :modern
    assert Protocol.profile(@legacy_version) == :legacy
    assert Protocol.profile("2099-01-01") == :unsupported
    assert Protocol.profile(nil) == :unsupported
  end

  test "profile! returns supported profiles and raises for unsupported versions" do
    assert Protocol.profile!(@modern_version) == :modern
    assert Protocol.profile!(@legacy_version) == :legacy

    assert_raise ArgumentError, ~r/unsupported MCP protocol version "2099-01-01"/, fn ->
      Protocol.profile!("2099-01-01")
    end

    assert_raise ArgumentError, ~r/unsupported MCP protocol version nil/, fn ->
      Protocol.profile!(nil)
    end
  end

  test "transport requests carry the selected protocol version; the engine derives the profile" do
    request = %Request{method: "tools/list", protocol_version: @modern_version}
    fields = request |> Map.from_struct() |> Map.keys()

    assert request.protocol_version == @modern_version
    assert :protocol_version in fields
    assert request.profile == nil
    refute :era in fields
  end
end
