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
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{})}
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
           JSON.encode!(%{"detail" => "missing"})}
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
      {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
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
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{})}
        end
      )

    [tool] = server.providers |> hd() |> Map.fetch!(:inner) |> Map.fetch!(:tools)

    assert get_in(tool.output_schema, ["properties", "child", "$ref"]) ==
             "#/components/schemas/Node"
  end

  test "operation parameters override path parameters and schema defaults are serialized" do
    parent = self()

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Overrides", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://override.example.com"}],
      "paths" => %{
        "/search" => %{
          "parameters" => [
            %{
              "name" => "query",
              "in" => "query",
              "description" => "path-level",
              "schema" => %{"type" => "string", "default" => "old"}
            }
          ],
          "get" => %{
            "operationId" => "search",
            "parameters" => [
              %{
                "name" => "query",
                "in" => "query",
                "description" => "operation-level",
                "schema" => %{"type" => "string", "default" => "new"}
              }
            ],
            "responses" => ok()
          }
        }
      }
    }

    server_name = "openapi-overrides-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn method, url, opts ->
          send(parent, {:request, method, url, opts})
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [tool] = FastestMCP.list_tools(server_name)
    assert Map.keys(tool.input_schema["properties"]) == ["query"]
    assert tool.input_schema["properties"]["query"]["description"] == "operation-level"

    assert %{"ok" => true} == FastestMCP.call_tool(server_name, "search", %{})
    assert_receive {:request, :get, "https://override.example.com/search", opts}
    assert opts[:query] == [{"query", "new"}]
  end

  test "parameter locations are whitelisted without creating atoms" do
    location = "untrusted_location_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(location) end

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Locations", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://locations.example.com"}],
      "paths" => %{
        "/unsafe" => %{
          "get" => %{
            "operationId" => "unsafe",
            "parameters" => [
              %{"name" => "value", "in" => location, "schema" => %{"type" => "string"}}
            ],
            "responses" => ok()
          }
        }
      }
    }

    assert_raise ArgumentError, ~r/unsupported OpenAPI parameter location/, fn ->
      FastestMCP.from_openapi(spec)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(location) end
  end

  test "parameter style defaults serialize arrays and path spaces correctly" do
    parent = self()

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Styles", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://styles.example.com"}],
      "paths" => %{
        "/items/{id}" => %{
          "get" => %{
            "operationId" => "styled",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              },
              %{"name" => "tag", "in" => "query", "schema" => %{"type" => "array"}},
              %{
                "name" => "compact",
                "in" => "query",
                "style" => "form",
                "explode" => false,
                "schema" => %{"type" => "array"}
              },
              %{
                "name" => "lang",
                "in" => "query",
                "schema" => %{"type" => "string", "default" => "en"}
              },
              %{"name" => "X-Flags", "in" => "header", "schema" => %{"type" => "array"}},
              %{"name" => "session", "in" => "cookie", "schema" => %{"type" => "string"}}
            ],
            "responses" => ok()
          }
        }
      }
    }

    server_name = "openapi-styles-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn method, url, opts ->
          send(parent, {:request, method, url, opts})
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "styled", %{
               "id" => "a b",
               "tag" => ["one", "two"],
               "compact" => ["a", "b"],
               "X-Flags" => ["fast", "safe"],
               "session" => "abc 123"
             })

    assert_receive {:request, :get, "https://styles.example.com/items/a%20b", opts}

    assert opts[:query] == [
             {"tag", "one"},
             {"tag", "two"},
             {"compact", "a,b"},
             {"lang", "en"}
           ]

    assert {"X-Flags", "fast,safe"} in opts[:headers]
    assert {"cookie", "session=abc+123"} in opts[:headers]
  end

  test "scalar and array JSON request bodies are sent without wrapper objects" do
    parent = self()

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Raw JSON", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://body.example.com"}],
      "paths" => %{
        "/array" => %{
          "post" => %{
            "operationId" => "send_array",
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{"type" => "array", "items" => %{"type" => "integer"}}
                }
              }
            },
            "responses" => ok()
          }
        },
        "/scalar" => %{
          "post" => %{
            "operationId" => "send_scalar",
            "requestBody" => %{
              "content" => %{"application/json" => %{"schema" => %{"type" => "string"}}}
            },
            "responses" => ok()
          }
        }
      }
    }

    server_name = "openapi-raw-body-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn method, url, opts ->
          send(parent, {:request, method, url, opts})
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "send_array", %{"body" => [1, 2, 3]})

    assert_receive {:request, :post, "https://body.example.com/array", array_opts}
    assert array_opts[:json] == [1, 2, 3]

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "send_scalar", %{"body" => "raw"})

    assert_receive {:request, :post, "https://body.example.com/scalar", scalar_opts}
    assert scalar_opts[:json] == "raw"
  end

  test "responses decode only JSON media types and structured JSON suffixes" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Response MIME", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://response.example.com"}],
      "paths" => %{
        "/text" => %{"get" => %{"operationId" => "text", "responses" => ok()}},
        "/problem" => %{"get" => %{"operationId" => "problem", "responses" => ok()}}
      }
    }

    server_name =
      "openapi-response-mime-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn
          :get, "https://response.example.com/text", _opts ->
            {:ok, 200, [{"content-type", "text/plain"}], ~s({"looks":"json"})}

          :get, "https://response.example.com/problem", _opts ->
            {:ok, 200, [{"content-type", "application/problem+json; charset=utf-8"}],
             ~s({"decoded":true})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert ~s({"looks":"json"}) == FastestMCP.call_tool(server_name, "text", %{})
    assert %{"decoded" => true} == FastestMCP.call_tool(server_name, "problem", %{})
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
