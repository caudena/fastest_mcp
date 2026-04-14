defmodule FastestMCP.SchemaDereferenceTest do
  use ExUnit.Case, async: false

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

  @output_schema %{
    "type" => "object",
    "$defs" => %{
      "Paint" => %{
        "type" => "object",
        "properties" => %{
          "hex" => %{"type" => "string"},
          "color" => %{"$ref" => "#/$defs/Color"}
        },
        "required" => ["hex", "color"]
      },
      "Color" => %{"type" => "string", "enum" => ["red", "green", "blue"]}
    },
    "$ref" => "#/$defs/Paint"
  }

  @simple_schema %{
    "type" => "object",
    "properties" => %{
      "a" => %{"type" => "integer"},
      "b" => %{"type" => "integer"}
    },
    "required" => ["a", "b"]
  }

  test "tool and resource template schemas are dereferenced by default" do
    server_name = "schema-default-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("paint", fn arguments, _ctx -> arguments end,
        input_schema: @input_schema,
        output_schema: @output_schema
      )
      |> FastestMCP.add_resource_template("paint://{color}", fn arguments, _ctx -> arguments end,
        parameters: @input_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    [tool] = FastestMCP.list_tools(server_name)
    [template] = FastestMCP.list_resource_templates(server_name)

    refute Map.has_key?(tool.input_schema, "$defs")
    refute Map.has_key?(tool.output_schema, "$defs")
    refute inspect(tool.input_schema) =~ "$ref"
    refute inspect(tool.output_schema) =~ "$ref"
    assert tool.input_schema["properties"]["color"]["enum"] == ["red", "green", "blue"]
    assert tool.output_schema["properties"]["color"]["enum"] == ["red", "green", "blue"]

    refute Map.has_key?(template.parameters, "$defs")
    refute inspect(template.parameters) =~ "$ref"
    assert template.parameters["properties"]["color"]["enum"] == ["red", "green", "blue"]
  end

  test "dereference_schemas false preserves refs and defs" do
    server_name = "schema-preserve-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, dereference_schemas: false)
      |> FastestMCP.add_tool("paint", fn arguments, _ctx -> arguments end,
        input_schema: @input_schema,
        output_schema: @output_schema
      )
      |> FastestMCP.add_resource_template("paint://{color}", fn arguments, _ctx -> arguments end,
        parameters: @input_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    [tool] = FastestMCP.list_tools(server_name)
    [template] = FastestMCP.list_resource_templates(server_name)

    assert Map.has_key?(tool.input_schema, "$defs")
    assert Map.has_key?(tool.output_schema, "$defs")
    assert inspect(tool.input_schema) =~ "$ref"
    assert inspect(tool.output_schema) =~ "$ref"

    assert Map.has_key?(template.parameters, "$defs")
    assert inspect(template.parameters) =~ "$ref"
  end

  test "dereferencing does not mutate stored component definitions" do
    server_name = "schema-immutability-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("paint", fn arguments, _ctx -> arguments end,
        input_schema: @input_schema,
        output_schema: @output_schema
      )
      |> FastestMCP.add_resource_template("paint://{color}", fn arguments, _ctx -> arguments end,
        parameters: @input_schema
      )

    assert Map.has_key?(hd(server.tools).input_schema, "$defs")
    assert Map.has_key?(hd(server.resource_templates).parameters, "$defs")

    assert {:ok, _pid} = FastestMCP.start_server(server)
    _ = FastestMCP.list_tools(server_name)
    _ = FastestMCP.list_resource_templates(server_name)

    assert Map.has_key?(hd(server.tools).input_schema, "$defs")
    assert Map.has_key?(hd(server.tools).output_schema, "$defs")
    assert Map.has_key?(hd(server.resource_templates).parameters, "$defs")
  end

  test "schemas without refs are returned unchanged" do
    server_name = "schema-no-ref-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("add", fn arguments, _ctx -> arguments end,
        input_schema: @simple_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    [tool] = FastestMCP.list_tools(server_name)
    assert tool.input_schema == @simple_schema
  end
end
