defmodule FastestMCP.SchemaAtomSafetyTest do
  use FastestMCP.Case, async: false

  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Schema
  alias FastestMCP.Transport.JSONRPC

  test "untrusted schema, method, and metadata strings do not create atoms after warmup" do
    Enum.each(1..20, &exercise_boundaries("warm-#{&1}"))
    {:ok, _compiled} = ProtocolSchema.compile_definition("2026-07-28", "ContentBlock")
    before_count = :erlang.system_info(:atom_count)

    Enum.each(1..200, &exercise_boundaries("untrusted-#{&1}"))

    assert :erlang.system_info(:atom_count) == before_count
  end

  defp exercise_boundaries(suffix) do
    property = "property-#{suffix}"

    schema = %{
      "type" => "object",
      "properties" => %{property => %{"type" => "string"}},
      "additionalProperties" => false
    }

    assert {:ok, compiled} = Schema.compile(schema)
    assert {:ok, %{^property => "value"}} = Schema.validate(compiled, %{property => "value"})
    assert {:ok, _meta} = Meta.validate(%{"com.example/#{suffix}" => true})
    method = "com.example/#{suffix}"

    assert {:ok, {:request, ^method, %{}, ^suffix}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => suffix,
               "method" => method,
               "params" => %{}
             })
  end
end
