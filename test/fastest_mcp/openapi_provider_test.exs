defmodule FastestMCP.OpenAPIProviderTest do
  use ExUnit.Case, async: false

  defp simple_spec do
    %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "OpenAPI Test API", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://api.example.com"}],
      "paths" => %{
        "/users/{id}" => %{
          "get" => %{
            "operationId" => "get_user",
            "summary" => "Get user by ID",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "integer"},
                "description" => "The user ID"
              },
              %{
                "name" => "include_details",
                "in" => "query",
                "schema" => %{"type" => "boolean"},
                "description" => "Whether to include expanded details"
              },
              %{
                "name" => "X-API-Key",
                "in" => "header",
                "required" => true,
                "schema" => %{"type" => "string"},
                "description" => "API key"
              }
            ],
            "responses" => %{
              "200" => %{
                "description" => "OK",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "id" => %{"type" => "integer"},
                        "name" => %{"type" => "string"}
                      }
                    }
                  }
                }
              }
            }
          }
        },
        "/users" => %{
          "post" => %{
            "operationId" => "create_user",
            "summary" => "Create user",
            "requestBody" => %{
              "required" => true,
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "name" => %{"type" => "string"},
                      "email" => %{"type" => "string", "format" => "email"}
                    },
                    "required" => ["name", "email"]
                  }
                }
              }
            },
            "responses" => %{
              "201" => %{
                "description" => "Created",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "id" => %{"type" => "integer"},
                        "name" => %{"type" => "string"},
                        "email" => %{"type" => "string"}
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  test "from_openapi creates a server with provider-backed tools" do
    server_name = "openapi-basic-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(simple_spec(),
        name: server_name,
        requester: fn _method, _url, _opts ->
          {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true})}
        end
      )

    assert server.name == server_name
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    tools = FastestMCP.list_tools(server_name)
    assert Enum.map(tools, & &1.name) == ["create_user", "get_user"]

    get_user = Enum.find(tools, &(&1.name == "get_user"))
    create_user = Enum.find(tools, &(&1.name == "create_user"))

    assert get_user.description == "Get user by ID"
    assert get_user.input_schema["properties"]["id"]["description"] == "The user ID"
    assert get_user.input_schema["properties"]["X-API-Key"]["description"] == "API key"
    assert get_user.input_schema["required"] == ["id", "X-API-Key"]
    assert get_user.output_schema["properties"]["id"]["type"] == "integer"

    assert MapSet.new(create_user.input_schema["required"]) == MapSet.new(["name", "email"])
    assert create_user.input_schema["properties"]["email"]["format"] == "email"
  end

  test "provider execution maps path query header and body arguments into HTTP requests" do
    parent = self()
    server_name = "openapi-exec-" <> Integer.to_string(System.unique_integer([:positive]))

    requester = fn method, url, opts ->
      send(parent, {:request, method, url, opts})
      {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true})}
    end

    server = FastestMCP.from_openapi(simple_spec(), name: server_name, requester: requester)
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "get_user", %{
               "id" => 123,
               "include_details" => true,
               "X-API-Key" => "secret"
             })

    assert_receive {:request, :get, "https://api.example.com/users/123", get_opts}, 1_000
    assert get_opts[:query] == [{"include_details", "true"}]
    assert get_opts[:headers] == [{"X-API-Key", "secret"}]

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "create_user", %{
               "name" => "Nate",
               "email" => "nate@example.com"
             })

    assert_receive {:request, :post, "https://api.example.com/users", post_opts}, 1_000
    assert post_opts[:json] == %{"name" => "Nate", "email" => "nate@example.com"}
  end
end
