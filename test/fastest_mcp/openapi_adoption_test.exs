defmodule FastestMCP.OpenAPIAdoptionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.{Error, Schema}
  alias FastestMCP.Providers.OpenAPI

  test "reference preparation honors schema bounds and embedded resource scopes" do
    body = %{"$ref" => "#/components/schemas/One"}

    components = %{
      "schemas" => %{
        "One" => %{
          "type" => "object",
          "properties" => %{"value" => %{"$ref" => "#/components/schemas/Two"}}
        },
        "Two" => %{"type" => "string"}
      }
    }

    assert_raise Schema.Error, ~r/schema limits/, fn ->
      OpenAPI.new(
        openapi_spec: spec(body, components: components),
        requester: requester(),
        schema_options: [max_resolved_resources: 1]
      )
    end

    scoped = %{
      "type" => "object",
      "properties" => %{
        "nested" => %{
          "$id" => "urn:example:nested-schema",
          "$defs" => %{"Text" => %{"type" => "string"}},
          "type" => "object",
          "properties" => %{"value" => %{"$ref" => "#/$defs/Text"}}
        }
      }
    }

    server = start_body(scoped)
    FastestMCP.call_tool!(server.name, "send", %{"body" => %{"nested" => %{"value" => "valid"}}})
    assert_receive {:request, _}

    assert_raise Error, fn ->
      FastestMCP.call_tool!(server.name, "send", %{"body" => %{"nested" => %{"value" => 1}}})
    end

    refute_receive {:request, _}
  end

  test "optional bodies remain absent, but supplied bodies satisfy the complete schema" do
    body = %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}},
      "required" => ["a", "b"]
    }

    server = start_body(body, required: false)
    assert %{} = FastestMCP.call_tool!(server.name, "send", %{})
    assert_receive {:request, opts}
    refute Keyword.has_key?(opts, :json)
    assert_raise Error, fn -> FastestMCP.call_tool!(server.name, "send", %{"a" => "partial"}) end
    refute_receive {:request, _}
    FastestMCP.call_tool!(server.name, "send", %{"a" => "one", "b" => "two"})
    assert_receive {:request, opts}
    assert opts[:json] == %{"a" => "one", "b" => "two"}
  end

  test "empty-property dictionaries and constrained objects keep a whole-body input" do
    for schema <- [
          %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => %{"type" => "string"}
          },
          %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "string"}},
            "minProperties" => 2
          }
        ] do
      server = start_body(schema)
      FastestMCP.call_tool!(server.name, "send", %{"body" => %{"a" => "one", "b" => "two"}})
      assert_receive {:request, opts}
      assert opts[:json] == %{"a" => "one", "b" => "two"}
    end
  end

  test "referenced body fields and sibling constraints both survive" do
    base = %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string", "minLength" => 2}},
      "required" => ["id"]
    }

    body = %{
      "$ref" => "#/components/schemas/Base",
      "properties" => %{
        "id" => %{"type" => "string", "maxLength" => 3},
        "extra" => %{"type" => "string"}
      },
      "required" => ["extra"]
    }

    server = start_body(body, components: %{"schemas" => %{"Base" => base}})
    FastestMCP.call_tool!(server.name, "send", %{"id" => "abc", "extra" => "ok"})
    assert_receive {:request, opts}
    assert opts[:json] == %{"id" => "abc", "extra" => "ok"}

    for id <- ["a", "abcd"] do
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server.name, "send", %{"id" => id, "extra" => "ok"})
      end
    end

    refute_receive {:request, _}
  end

  test "raw media strings keep their bytes and declared Content-Type" do
    for media <- ["text/plain; charset=utf-8", "application/xml", "application/octet-stream"] do
      server = start_body(%{"type" => "string"}, media: media)
      FastestMCP.call_tool!(server.name, "send", %{"body" => "<raw>é</raw>\n"})
      assert_receive {:request, opts}
      assert opts[:body] == "<raw>é</raw>\n"
      assert opts[:content_type] == media
      refute Keyword.has_key?(opts, :json)
    end
  end

  test "multipart arrays use existing repeated-field HTTP encoding" do
    schema = %{
      "type" => "object",
      "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
    }

    server = start_body(schema, media: "multipart/form-data")
    FastestMCP.call_tool!(server.name, "send", %{"tags" => ["one", "two"]})
    assert_receive {:request, opts}
    assert opts[:multipart] == [{"tags", "one"}, {"tags", "two"}]
  end

  test "annotation values remain data and parameter examples preserve false and zero" do
    opaque = %{
      "nullable" => true,
      "$ref" => "#/components/schemas/NotASchema",
      "type" => "object"
    }

    body = %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "object", "default" => opaque, "examples" => [opaque]}
      }
    }

    server = start_body(body)
    [tool] = tools(server)
    assert get_in(tool.input_schema, ["properties", "value", "default"]) == opaque
    assert get_in(tool.input_schema, ["properties", "value", "examples"]) == [opaque]

    for example <- [false, 0, ""] do
      spec = spec(body)
      parameter = %{"name" => "q", "in" => "query", "schema" => %{}, "example" => example}
      spec = put_in(spec, ["paths", "/send", "post", "parameters"], [parameter])
      [tool] = OpenAPI.new(openapi_spec: spec, requester: requester()).tools
      assert get_in(tool.input_schema, ["properties", "q", "examples"]) == [example]
    end
  end

  test "schema-local definitions survive embedding and generated definition names cannot overwrite them" do
    schema = %{
      "type" => "object",
      "$defs" => %{"__openapi" => %{"type" => "string"}},
      "properties" => %{
        "local" => %{"$ref" => "#/$defs/__openapi"},
        "remote" => %{"$ref" => "#/components/schemas/A~1B"}
      }
    }

    server = start_body(schema, components: %{"schemas" => %{"A/B" => %{"type" => "integer"}}})
    FastestMCP.call_tool!(server.name, "send", %{"body" => %{"local" => "yes", "remote" => 1}})
    assert_receive {:request, _}

    assert_raise Error, fn ->
      FastestMCP.call_tool!(server.name, "send", %{"body" => %{"local" => 1, "remote" => "no"}})
    end

    refute_receive {:request, _}
  end

  test "shared reference graphs stay proportional to their definitions" do
    defs =
      Enum.reduce(1..16, %{"N0" => %{"type" => "string"}}, fn i, defs ->
        Map.put(defs, "N#{i}", %{
          "type" => "object",
          "properties" => %{
            "left" => %{"$ref" => "#/components/schemas/N#{i - 1}"},
            "right" => %{"$ref" => "#/components/schemas/N#{i - 1}"}
          }
        })
      end)

    server = start_body(%{"$ref" => "#/components/schemas/N16"}, components: %{"schemas" => defs})
    [tool] = tools(server)
    assert byte_size(JSON.encode!(tool.input_schema)) < 20_000

    assert {:ok, _} =
             Schema.validate(tool.compiled_input_schema, %{"left" => %{}, "right" => %{}})
  end

  test "unresolved operation Reference Objects fail during construction" do
    spec =
      put_in(spec(%{"type" => "string"}), ["paths", "/send", "post", "requestBody"], %{
        "$ref" => "#/components/requestBodies/Missing"
      })

    assert_raise ArgumentError, ~r/unresolved OpenAPI reference/, fn ->
      OpenAPI.new(openapi_spec: spec, requester: requester())
    end
  end

  defp start_body(body, opts \\ []) do
    name = "openapi-adoption-#{System.unique_integer([:positive])}"
    server = FastestMCP.from_openapi(spec(body, opts), name: name, requester: requester())
    assert {:ok, _} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(name) end)
    server
  end

  defp tools(server), do: hd(server.providers).inner.tools

  defp requester do
    parent = self()

    fn _, _, opts ->
      send(parent, {:request, opts})
      {:ok, 200, [{"content-type", "application/json"}], "{}"}
    end
  end

  defp spec(body, opts \\ []) do
    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Adoption", "version" => "1"},
      "components" => Keyword.get(opts, :components, %{}),
      "paths" => %{
        "/send" => %{
          "post" => %{
            "operationId" => "send",
            "requestBody" => %{
              "required" => Keyword.get(opts, :required, true),
              "content" => %{Keyword.get(opts, :media, "application/json") => %{"schema" => body}}
            },
            "responses" => %{"200" => %{"description" => "ok"}}
          }
        }
      }
    }
  end
end
