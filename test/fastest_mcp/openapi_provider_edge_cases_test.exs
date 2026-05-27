defmodule FastestMCP.OpenAPIProviderEdgeCasesTest do
  use ExUnit.Case, async: false

  test "provider can be built with requester only and empty paths" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Requester Only", "version" => "1.0.0"},
      "paths" => %{}
    }

    server =
      FastestMCP.from_openapi(spec,
        name: "openapi-empty-" <> Integer.to_string(System.unique_integer([:positive])),
        requester: fn _method, _url, _opts ->
          {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
    assert FastestMCP.list_tools(server.name) == []
  end

  test "provider without server url or requester raises" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "No Servers", "version" => "1.0.0"},
      "paths" => %{}
    }

    assert_raise ArgumentError, ~r/requires :base_url, a spec server URL, or a :requester/, fn ->
      FastestMCP.from_openapi(spec)
    end
  end

  test "non-2xx openapi responses surface as FastestMCP errors instead of schema failures" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Errors", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://errors.example.com"}],
      "paths" => %{
        "/users/{id}" => %{
          "get" => %{
            "operationId" => "get_user",
            "summary" => "Get user",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "integer"}
              }
            ],
            "responses" => %{"200" => %{"description" => "OK"}}
          }
        }
      }
    }

    server_name = "openapi-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn _method, _url, _opts ->
          {:ok, 404, [{"content-type", "application/json"}],
           Jason.encode!(%{"detail" => "missing"})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    error =
      assert_raise FastestMCP.Error, fn ->
        FastestMCP.call_tool(server_name, "get_user", %{"id" => 999})
      end

    assert error.code == :bad_request
    assert error.details.status == 404
    assert error.details.body == %{"detail" => "missing"}
  end

  test "request serialization supports json variants, forms, multipart, and cookies" do
    parent = self()

    server_name =
      "openapi-serialization-" <> Integer.to_string(System.unique_integer([:positive]))

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Serialization", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://api.example.com"}],
      "paths" => %{
        "/json" => %{
          "post" => %{
            "operationId" => "send_json",
            "requestBody" => body("application/merge-patch+json; charset=utf-8"),
            "responses" => ok()
          }
        },
        "/form" => %{
          "post" => %{
            "operationId" => "send_form",
            "requestBody" => body("application/x-www-form-urlencoded"),
            "responses" => ok()
          }
        },
        "/upload" => %{
          "post" => %{
            "operationId" => "send_upload",
            "requestBody" => body("multipart/form-data"),
            "responses" => ok()
          }
        },
        "/cookie" => %{
          "get" => %{
            "operationId" => "cookie_auth",
            "parameters" => [
              %{
                "name" => "session",
                "in" => "cookie",
                "schema" => %{"type" => "string"},
                "required" => true
              }
            ],
            "responses" => ok()
          }
        }
      }
    }

    requester = fn method, url, opts ->
      send(parent, {:request, method, url, opts})
      {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true})}
    end

    server = FastestMCP.from_openapi(spec, name: server_name, requester: requester)
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "send_json", %{"name" => "Ada"})

    assert_receive {:request, :post, "https://api.example.com/json", json_opts}
    assert json_opts[:json] == %{"name" => "Ada"}
    assert json_opts[:content_type] == "application/merge-patch+json; charset=utf-8"

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "send_form", %{"name" => "Ada"})

    assert_receive {:request, :post, "https://api.example.com/form", form_opts}
    assert form_opts[:form] == %{"name" => "Ada"}

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "send_upload", %{"name" => "Ada"})

    assert_receive {:request, :post, "https://api.example.com/upload", upload_opts}
    assert upload_opts[:multipart] == %{"name" => "Ada"}

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "cookie_auth", %{"session" => "abc 123"})

    assert_receive {:request, :get, "https://api.example.com/cookie", cookie_opts}
    assert {"cookie", "session=abc+123"} in cookie_opts[:headers]
  end

  test "circular component refs remain unresolved instead of recursing" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Circular", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://circular.example.com"}],
      "components" => %{
        "schemas" => %{
          "Node" => %{
            "type" => "object",
            "properties" => %{"child" => %{"$ref" => "#/components/schemas/Node"}}
          }
        }
      },
      "paths" => %{
        "/node" => %{
          "get" => %{
            "operationId" => "get_node",
            "responses" => %{
              "200" => %{
                "description" => "OK",
                "content" => %{
                  "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Node"}}
                }
              }
            }
          }
        }
      }
    }

    server =
      FastestMCP.from_openapi(spec,
        name: "openapi-circular-" <> Integer.to_string(System.unique_integer([:positive])),
        requester: fn _method, _url, _opts ->
          {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{})}
        end
      )

    [tool] = server.providers |> hd() |> Map.fetch!(:inner) |> Map.fetch!(:tools)

    assert get_in(tool.output_schema, ["properties", "child", "$ref"]) ==
             "#/components/schemas/Node"
  end

  defp body(content_type) do
    %{
      "content" => %{
        content_type => %{
          "schema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        }
      }
    }
  end

  defp ok do
    %{"200" => %{"description" => "OK", "content" => %{"application/json" => %{}}}}
  end
end
