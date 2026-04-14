defmodule FastestMCP.OpenAPIProviderFeaturesTest do
  use ExUnit.Case, async: false

  defp feature_spec do
    %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Features API", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://features.example.com"}],
      "components" => %{
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "integer"},
              "name" => %{"type" => "string"},
              "email" => %{"type" => "string"}
            },
            "required" => ["name", "email"]
          }
        },
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"type" => "integer"},
            "description" => "User identifier"
          }
        }
      },
      "paths" => %{
        "/users/{id}" => %{
          "parameters" => [%{"$ref" => "#/components/parameters/UserId"}],
          "put" => %{
            "operationId" => "update_user",
            "summary" => "Update user",
            "requestBody" => %{
              "required" => true,
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "id" => %{"type" => "integer"},
                      "name" => %{"type" => "string"},
                      "email" => %{"type" => "string"}
                    },
                    "required" => ["name", "email"]
                  }
                }
              }
            },
            "responses" => %{
              "200" => %{
                "description" => "Updated",
                "content" => %{
                  "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/User"}}
                }
              }
            }
          }
        },
        "/search" => %{
          "get" => %{
            "operationId" => "search_users",
            "summary" => "Search users",
            "parameters" => [
              %{
                "name" => "filter",
                "in" => "query",
                "style" => "deepObject",
                "explode" => true,
                "schema" => %{
                  "type" => "object",
                  "properties" => %{
                    "age" => %{
                      "type" => "object",
                      "properties" => %{
                        "min" => %{"type" => "integer"},
                        "max" => %{"type" => "integer"}
                      }
                    },
                    "active" => %{"type" => "boolean"}
                  }
                }
              }
            ],
            "responses" => %{
              "200" => %{
                "description" => "OK",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{"results" => %{"type" => "array"}}
                    }
                  }
                }
              }
            }
          }
        },
        "/api/{version}/users/{user_id}" => %{
          "get" => %{
            "operationId" => "parameter_docs",
            "summary" => "My endpoint",
            "parameters" => [
              %{
                "name" => "version",
                "in" => "path",
                "required" => true,
                "description" => "API version",
                "schema" => %{"type" => "string"}
              },
              %{
                "name" => "user_id",
                "in" => "path",
                "required" => true,
                "description" => "The user ID",
                "schema" => %{"type" => "string"}
              }
            ],
            "responses" => %{"200" => %{"description" => "OK"}}
          }
        }
      }
    }
  end

  test "openapi provider resolves refs, handles collisions, and preserves parameter docs in schemas" do
    parent = self()
    server_name = "openapi-features-" <> Integer.to_string(System.unique_integer([:positive]))

    requester = fn method, url, opts ->
      send(parent, {:request, method, url, opts})
      {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true})}
    end

    server = FastestMCP.from_openapi(feature_spec(), name: server_name, requester: requester)
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    tools = FastestMCP.list_tools(server_name)
    update_user = Enum.find(tools, &(&1.name == "update_user"))
    search_users = Enum.find(tools, &(&1.name == "search_users"))
    parameter_docs = Enum.find(tools, &(&1.name == "parameter_docs"))

    assert Map.keys(update_user.input_schema["properties"]) |> MapSet.new() ==
             MapSet.new(["id", "id__path", "name", "email"])

    assert MapSet.new(update_user.input_schema["required"]) ==
             MapSet.new(["id__path", "name", "email"])

    assert update_user.input_schema["properties"]["id__path"]["description"] == "User identifier"
    assert update_user.output_schema["properties"]["email"]["type"] == "string"

    assert search_users.input_schema["properties"]["filter"]["properties"]["age"]["properties"][
             "min"
           ]["type"] ==
             "integer"

    assert parameter_docs.description == "My endpoint"
    assert parameter_docs.input_schema["properties"]["user_id"]["description"] == "The user ID"
    refute String.contains?(parameter_docs.description, "user ID")

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "update_user", %{
               "id__path" => 123,
               "id" => 456,
               "name" => "Nate",
               "email" => "nate@example.com"
             })

    assert_receive {:request, :put, "https://features.example.com/users/123", update_opts}, 1_000
    assert update_opts[:json] == %{"id" => 456, "name" => "Nate", "email" => "nate@example.com"}

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "search_users", %{
               "filter" => %{"age" => %{"min" => 20, "max" => 40}, "active" => true}
             })

    assert_receive {:request, :get, "https://features.example.com/search", search_opts}, 1_000

    assert MapSet.new(search_opts[:query]) ==
             MapSet.new([
               {"filter[age][min]", "20"},
               {"filter[age][max]", "40"},
               {"filter[active]", "true"}
             ])
  end
end
