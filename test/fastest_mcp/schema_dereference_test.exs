defmodule FastestMCP.SchemaDereferenceTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Component

  @input_schema %{
    "type" => "object",
    "$defs" => %{
      "Color" => %{"type" => "string", "enum" => ["red", "green", "blue"]}
    },
    "properties" => %{
      "color" => %{"$ref" => "#/$defs/Color"},
      "opacity" => %{"type" => "number"}
    },
    "required" => ["color"]
  }

  test "component schemas preserve standards-compliant references" do
    server =
      FastestMCP.server("schema-references")
      |> FastestMCP.add_tool("paint", fn arguments, _ctx -> arguments end,
        input_schema: @input_schema
      )
      |> FastestMCP.add_resource_template(
        "paint://{color}",
        fn arguments, _ctx -> arguments end,
        parameters: @input_schema
      )

    [tool] = server.tools
    [template] = server.resource_templates

    assert Map.has_key?(tool.input_schema, "$defs")
    assert tool.input_schema["properties"]["color"] == %{"$ref" => "#/$defs/Color"}
    assert Map.has_key?(template.parameters, "$defs")
    assert template.parameters["properties"]["color"] == %{"$ref" => "#/$defs/Color"}
  end

  test "removed schema dereferencing options fail fast even when false" do
    for value <- [true, false] do
      assert_raise ArgumentError,
                   ~r/dereference_schemas was removed.*schema_options resolver support/,
                   fn ->
                     FastestMCP.server("removed-dereference-option", dereference_schemas: value)
                   end
    end

    refute function_exported?(FastestMCP.Middleware, :dereference_refs, 0)
    refute function_exported?(FastestMCP.Middleware, :dereference_refs, 1)
  end

  test "a reference that cannot be resolved is named when the schema is compiled" do
    remote_uri = "https://schemas.example/tag.json"

    schema = %{
      "type" => "object",
      "properties" => %{"tag" => %{"$ref" => remote_uri}},
      "required" => ["tag"]
    }

    assert {:error, error} = FastestMCP.Schema.compile(schema)
    assert error.message == ~s(could not resolve JSON Schema reference "#{remote_uri}")
    assert [%{keyword: "$ref", message: message}] = error.violations
    assert message =~ remote_uri

    error =
      assert_raise FastestMCP.Schema.Error, fn ->
        FastestMCP.server("unresolved-reference")
        |> FastestMCP.add_tool("tag_note", fn arguments, _ctx -> arguments end,
          input_schema: schema
        )
      end

    assert error.message =~ remote_uri

    assert {:error, error} =
             FastestMCP.Schema.compile(%{
               "type" => "object",
               "properties" => %{"tag" => %{"$ref" => "#/$defs/missing"}}
             })

    assert error.message == ~s(could not resolve JSON Schema reference "#/$defs/missing")
  end

  test "explicit schema_options resolver compiles remote references without rewriting them" do
    remote_uri = "https://schemas.example/color"

    resolver = fn
      ^remote_uri -> {:ok, %{"type" => "string", "enum" => ["red", "green", "blue"]}}
      _uri -> {:error, :not_found}
    end

    schema = %{
      "type" => "object",
      "properties" => %{"color" => %{"$ref" => remote_uri}},
      "required" => ["color"]
    }

    server =
      FastestMCP.server("remote-schema-resolver", schema_options: [resolver: resolver])
      |> FastestMCP.add_tool("paint", fn arguments, _ctx -> arguments end, input_schema: schema)

    [tool] = server.tools
    assert tool.input_schema == schema
    assert Component.validate_arguments(tool, %{"color" => "red"}) == %{"color" => "red"}

    assert_raise FastestMCP.Error, fn ->
      Component.validate_arguments(tool, %{"color" => "purple"})
    end
  end
end
