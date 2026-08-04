defmodule FastestMCP.InputValidationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error

  @numeric_schema %{
    "type" => "object",
    "properties" => %{
      "a" => %{"type" => "integer"},
      "b" => %{"type" => "integer"}
    },
    "required" => ["a", "b"]
  }

  @profile_schema %{
    "type" => "object",
    "properties" => %{
      "profile" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"},
          "email" => %{"type" => "string"}
        },
        "required" => ["name", "age", "email"]
      }
    },
    "required" => ["profile"]
  }

  test "tool arguments must already have the declared JSON types" do
    server_name = "input-types-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("add", fn %{"a" => a, "b" => b}, _ctx -> a + b end,
        input_schema: @numeric_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 30 == FastestMCP.call_tool(server_name, "add", %{"a" => 10, "b" => 20})

    assert_raise Error, ~r/#\/a value has an invalid JSON type/, fn ->
      FastestMCP.call_tool(server_name, "add", %{"a" => "10", "b" => 20})
    end
  end

  test "the removed strict_input_validation option fails with migration guidance" do
    assert_raise ArgumentError,
                 ~r/strict_input_validation was removed; JSON Schema validation is always non-coercing/,
                 fn ->
                   FastestMCP.server("removed-strict-option", strict_input_validation: true)
                 end
  end

  test "nested objects are validated without parsing stringified JSON" do
    server_name = "input-nested-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "create_user",
        fn %{"profile" => profile}, _ctx ->
          "#{profile["name"]}:#{profile["age"]}:#{profile["email"]}"
        end,
        input_schema: @profile_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    profile = %{"name" => "Alice", "age" => 30, "email" => "alice@example.com"}

    assert "Alice:30:alice@example.com" ==
             FastestMCP.call_tool(server_name, "create_user", %{"profile" => profile})

    encoded = JSON.encode!(profile)

    assert_raise Error, ~r/#\/profile value has an invalid JSON type/, fn ->
      FastestMCP.call_tool(server_name, "create_user", %{"profile" => encoded})
    end
  end

  test "resource template parameters retain their URI string representation" do
    server_name = "template-params-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "pattern" => "^[0-9]+$"},
        "enabled" => %{"type" => "string", "enum" => ["true", "false"]}
      },
      "required" => ["id"]
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template(
        "item://{id}{?enabled}",
        fn %{"id" => id, "enabled" => enabled}, _ctx ->
          %{id: id, enabled: enabled}
        end,
        parameters: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{id: "41", enabled: "true"} ==
             FastestMCP.read_resource(server_name, "item://41?enabled=true")
  end

  test "prompt required arguments are validated" do
    server_name = "prompt-required-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}" end,
        arguments: [%{name: "name", description: "Name", required: true}]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise Error, ~r/missing required argument "name"/, fn ->
      FastestMCP.render_prompt(server_name, "greet", %{})
    end
  end

  test "nullable type unions accept nil and strings" do
    server_name = "input-nullable-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "category" => %{"type" => ["string", "null"]}
      }
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo_category", fn %{"category" => category}, _ctx -> category end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert nil == FastestMCP.call_tool(server_name, "echo_category", %{"category" => nil})
    assert "books" == FastestMCP.call_tool(server_name, "echo_category", %{"category" => "books"})
  end

  test "anyOf preserves the matching submitted type" do
    server_name = "input-anyof-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "value" => %{
          "anyOf" => [
            %{"type" => "integer"},
            %{"type" => "string"}
          ]
        }
      },
      "required" => ["value"]
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo_value", fn %{"value" => value}, _ctx -> value end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 41 == FastestMCP.call_tool(server_name, "echo_value", %{"value" => 41})
    assert "41" == FastestMCP.call_tool(server_name, "echo_value", %{"value" => "41"})
  end

  test "oneOf rejects values that match multiple branches" do
    server_name = "input-oneof-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "value" => %{
          "oneOf" => [
            %{"type" => "integer"},
            %{"type" => "number"}
          ]
        }
      },
      "required" => ["value"]
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo_value", fn %{"value" => value}, _ctx -> value end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise Error, ~r/does not match exactly one allowed schema/, fn ->
      FastestMCP.call_tool(server_name, "echo_value", %{"value" => 7})
    end
  end

  test "boolean property schemas and additionalProperties false are enforced" do
    server_name =
      "input-boolean-schema-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "anything" => true,
        "blocked" => false
      },
      "additionalProperties" => false
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn args, _ctx -> args end, input_schema: schema)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"anything" => %{"nested" => "value"}} ==
             FastestMCP.call_tool(server_name, "echo", %{
               "anything" => %{"nested" => "value"}
             })

    assert_raise Error, ~r/#\/blocked/, fn ->
      FastestMCP.call_tool(server_name, "echo", %{"blocked" => "nope"})
    end

    assert_raise Error, ~r/additional properties are not allowed/, fn ->
      FastestMCP.call_tool(server_name, "echo", %{"extra" => "nope"})
    end
  end
end
