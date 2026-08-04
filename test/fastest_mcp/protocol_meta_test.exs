defmodule FastestMCP.Protocol.MetaTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol.Meta

  test "accepts unprefixed and reverse-DNS application keys" do
    assert {:ok, %{"trace_id" => 1, "com.example/feature.name" => true}} =
             Meta.validate(%{"trace_id" => 1, "com.example/feature.name" => true})
  end

  test "rejects malformed names and reserved second labels" do
    assert {:error, _} = Meta.validate(%{"bad/ending-" => true})
    assert {:error, _} = Meta.validate(%{"io.modelcontextprotocol/related-task" => %{}})
    assert {:error, _} = Meta.validate(%{"dev.mcp/tool" => %{}})
  end

  test "permits exact protocol-owned keys only when explicitly selected" do
    key = "io.modelcontextprotocol/related-task"

    assert {:ok, %{^key => %{taskId: "one"}}} =
             Meta.validate(%{key => %{taskId: "one"}}, allowed_reserved: [key])

    assert {:error, _reason} =
             Meta.validate(%{key => %{}}, allowed_reserved: [key])

    assert {:error, _reason} =
             Meta.validate(%{key => %{taskId: 1}}, allowed_reserved: [key])
  end

  test "separates application, peer, and protocol reserved-key policies" do
    future_key = "io.modelcontextprotocol/future-feature"

    assert {:error, _reason} = Meta.validate(%{future_key => %{}}, source: :application)
    assert {:ok, %{^future_key => %{}}} = Meta.validate(%{future_key => %{}}, source: :peer)
    assert {:error, _reason} = Meta.validate(%{future_key => %{}}, source: :protocol)

    known_key = "io.modelcontextprotocol/related-task"

    assert {:ok, %{^known_key => %{"taskId" => "one"}}} =
             Meta.validate(%{known_key => %{"taskId" => "one"}}, source: :peer)

    assert {:error, _reason} = Meta.validate(%{known_key => %{}}, source: :peer)
  end

  test "rejects duplicate keys after native key normalization" do
    assert {:error, reason} = Meta.validate(%{:trace => 1, "trace" => 2})
    assert reason =~ "duplicate normalized _meta key"

    assert {:error, "_meta keys must be strings"} = Meta.validate(%{{:tuple, :key} => true})
  end

  test "tree validation permits standard protocol metadata and rejects nested reserved keys" do
    assert :ok =
             Meta.validate_tree(%{
               "params" => %{
                 "_meta" => %{
                   "io.modelcontextprotocol/related-task" => %{"taskId" => "one"}
                 }
               }
             })

    assert {:error, _reason} =
             Meta.validate_tree(%{
               "result" => %{
                 "content" => [
                   %{"type" => "text", "text" => "ok", "_meta" => %{"dev.mcp/x" => 1}}
                 ]
               }
             })

    assert :ok = Meta.validate_tree(%{"_meta" => %{"application" => %{"_meta" => []}}})

    assert :ok =
             Meta.validate_tree(%{"_meta" => %{"io.modelcontextprotocol/future" => %{}}},
               source: :peer
             )
  end
end
