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

  test "tool arguments are coerced by default when input_schema is provided" do
    server_name = "input-coerce-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("add", fn %{"a" => a, "b" => b}, _ctx -> a + b end,
        input_schema: @numeric_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 30 == FastestMCP.call_tool(server_name, "add", %{"a" => "10", "b" => "20"})
  end

  test "strict_input_validation rejects coercion" do
    server_name = "input-strict-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, strict_input_validation: true)
      |> FastestMCP.add_tool("add", fn %{"a" => a, "b" => b}, _ctx -> a + b end,
        input_schema: @numeric_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise Error, ~r/a must be an integer/, fn ->
      FastestMCP.call_tool(server_name, "add", %{"a" => "10", "b" => 20})
    end
  end

  test "nested object values accept stringified json in non-strict mode" do
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

    profile = Jason.encode!(%{"name" => "Alice", "age" => "30", "email" => "alice@example.com"})

    assert "Alice:30:alice@example.com" ==
             FastestMCP.call_tool(server_name, "create_user", %{"profile" => profile})
  end

  test "resource template parameters are coerced through parameters schema" do
    server_name = "template-params-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "integer"},
        "enabled" => %{"type" => "boolean"}
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

    assert %{id: 41, enabled: true} ==
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

  test "nullable type unions accept nil in strict mode" do
    server_name = "input-nullable-" <> Integer.to_string(System.unique_integer([:positive]))

    schema = %{
      "type" => "object",
      "properties" => %{
        "category" => %{"type" => ["string", "null"]}
      }
    }

    server =
      FastestMCP.server(server_name, strict_input_validation: true)
      |> FastestMCP.add_tool("echo_category", fn %{"category" => category}, _ctx -> category end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert nil == FastestMCP.call_tool(server_name, "echo_category", %{"category" => nil})
    assert "books" == FastestMCP.call_tool(server_name, "echo_category", %{"category" => "books"})
  end

  test "anyOf accepts the first matching coercible schema in non-strict mode" do
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

    assert 41 == FastestMCP.call_tool(server_name, "echo_value", %{"value" => "41"})
    assert "alpha" == FastestMCP.call_tool(server_name, "echo_value", %{"value" => "alpha"})
  end

  test "oneOf rejects ambiguous matches in strict mode" do
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
      FastestMCP.server(server_name, strict_input_validation: true)
      |> FastestMCP.add_tool("echo_value", fn %{"value" => value}, _ctx -> value end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise Error, ~r/must match exactly one allowed shape/, fn ->
      FastestMCP.call_tool(server_name, "echo_value", %{"value" => 7})
    end
  end
end
