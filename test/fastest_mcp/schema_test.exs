defmodule FastestMCP.SchemaTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.Schema
  alias FastestMCP.Schema.HTTPResolver
  alias FastestMCP.Tools.Result, as: ToolResult

  @legacy_version "2025-11-25"

  @object_schema %{
    "type" => "object",
    "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}},
    "required" => ["count"],
    "additionalProperties" => false
  }

  test "vendored protocol schemas expose definitions for their selected versions" do
    assert {:ok, legacy_initialize} =
             Schema.compile_protocol_definition(@legacy_version, "InitializeRequest")

    assert legacy_initialize.source["type"] == "object"

    assert {:ok, modern_discover} =
             Schema.compile_protocol_definition("2026-07-28", "DiscoverRequest")

    assert modern_discover.source["type"] == "object"

    assert {:error, legacy_error} =
             Schema.compile_protocol_definition(@legacy_version, "DiscoverRequest")

    assert legacy_error.message =~ "unknown MCP protocol schema definition"

    assert {:error, modern_error} =
             Schema.compile_protocol_definition("2026-07-28", "InitializeRequest")

    assert modern_error.message =~ "unknown MCP protocol schema definition"
  end

  test "tagged protocol definitions are cached and selectable by direction and method" do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "schema-test", "version" => "1.0.0"}
      }
    }

    assert {:ok, ^initialize} =
             Schema.validate_protocol(
               @legacy_version,
               :client_to_server,
               :request,
               "initialize",
               initialize
             )

    assert {:error, error} =
             Schema.validate_protocol(
               @legacy_version,
               :client_to_server,
               :request,
               "initialize",
               put_in(initialize, ["params", "clientInfo"], %{"name" => "missing-version"})
             )

    assert error.phase == :validation

    assert {:error, error} =
             Schema.compile_protocol(
               @legacy_version,
               :server_to_client,
               :request,
               "tools/call"
             )

    assert error.message =~ "unsupported server_to_client request method"
    assert Schema.protocol_supported?(@legacy_version, :client_to_server, :request, "tools/call")

    refute Schema.protocol_supported?(
             @legacy_version,
             :server_to_client,
             :request,
             "tools/call"
           )

    assert Schema.protocol_supported?(
             @legacy_version,
             :server_to_client,
             :response,
             "tools/call"
           )

    assert Schema.protocol_supported?(
             @legacy_version,
             :server_to_client,
             :task_response,
             "tools/call"
           )

    refute Schema.protocol_supported?(
             @legacy_version,
             :client_to_server,
             :task_response,
             "tools/call"
           )

    assert {:ok, first} = Schema.compile_protocol_definition(@legacy_version, "ContentBlock")
    assert {:ok, second} = Schema.compile_protocol_definition(@legacy_version, "ContentBlock")
    assert first === second
  end

  test "compiled elicitation schema follows authoritative number semantics" do
    compiled =
      Schema.compile_protocol_definition!(@legacy_version, "ElicitRequestFormParams")

    params = %{
      "message" => "Decimal bounds and default",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{
          "score" => %{
            "type" => "number",
            "minimum" => 0.5,
            "maximum" => 99.9,
            "default" => 95.5
          }
        }
      }
    }

    assert {:ok, ^params} = Schema.validate(compiled, params)

    invalid = put_in(params, ["requestedSchema", "properties", "score", "default"], "95.5")
    assert {:error, _error} = Schema.validate(compiled, invalid)

    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{"action" => "accept", "content" => %{"score" => 95.5}}
    }

    assert {:ok, ^response} =
             Schema.validate_protocol(
               @legacy_version,
               :client_to_server,
               :response,
               "elicitation/create",
               response
             )

    invalid_response = put_in(response, ["result", "content", "score"], %{"nested" => true})

    assert {:error, _error} =
             Schema.validate_protocol(
               @legacy_version,
               :client_to_server,
               :response,
               "elicitation/create",
               invalid_response
             )
  end

  test "method-specific response schemas validate exact results and canonical errors" do
    result_response = %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "result" => %{
        "content" => [%{"type" => "text", "text" => "done"}],
        "structuredContent" => %{"ok" => true}
      }
    }

    assert {:ok, ^result_response} =
             Schema.validate_protocol(
               @legacy_version,
               :server_to_client,
               :response,
               "tools/call",
               result_response
             )

    invalid_result = put_in(result_response, ["result", "content"], "not-an-array")

    assert {:error, _error} =
             Schema.validate_protocol(
               @legacy_version,
               :server_to_client,
               :response,
               "tools/call",
               invalid_result
             )

    error_response = %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "error" => %{"code" => -32_602, "message" => "Invalid params"}
    }

    assert {:ok, ^error_response} =
             Schema.validate_protocol(
               @legacy_version,
               :server_to_client,
               :response,
               "tools/call",
               error_response
             )
  end

  test "Draft 2020-12 validation is non-coercing and returns the submitted value" do
    assert {:ok, compiled} = Schema.compile(@object_schema)
    assert compiled.dialect == "https://json-schema.org/draft/2020-12/schema"

    assert {:ok, boolean_schema} = Schema.compile(true)
    assert {:ok, "unchanged"} = Schema.validate(boolean_schema, "unchanged")

    value = %{"count" => 2}

    assert {:ok, ^value} = Schema.validate(compiled, value)

    assert {:error, error} = Schema.validate(compiled, %{"count" => "2"})
    assert error.phase == :validation
    assert error.message == "#/count value has an invalid JSON type"
    assert [%{instance_path: "#/count", keyword: "type"} | _rest] = error.violations
    refute inspect(error) =~ ~s("count" => "2")
  end

  test "Draft 7 can be selected explicitly and unsupported dialects fail" do
    draft_7 = Map.put(@object_schema, "$schema", "http://json-schema.org/draft-07/schema#")
    assert {:ok, compiled} = Schema.compile(draft_7)
    assert compiled.dialect == "http://json-schema.org/draft-07/schema"

    assert {:error, error} =
             Schema.compile(Map.put(@object_schema, "$schema", "https://example.com/draft-99"))

    assert error.phase == :compile
    assert error.message =~ "unsupported JSON Schema dialect"

    assert {:error, malformed} = Schema.compile(%{"$schema" => 20_201_200})
    assert malformed.phase == :compile
    assert malformed.message == "JSON Schema $schema must be a string"
  end

  test "schema definitions must satisfy their selected meta-schema" do
    assert {:error, error} =
             Schema.compile(%{"type" => "object", "required" => "not-an-array"})

    assert error.phase == :compile
    assert error.message =~ "invalid JSON Schema"
    assert Enum.any?(error.violations, &(&1.keyword == "type"))

    assert {:error, draft_7_error} =
             Schema.compile(%{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "type" => "string",
               "minLength" => -1
             })

    assert draft_7_error.phase == :compile
    assert Enum.any?(draft_7_error.violations, &(&1.keyword == "minimum"))
  end

  test "protocol schemas assert MCP formats and corrected task number semantics" do
    task_metadata = Schema.compile_protocol_definition!(@legacy_version, "TaskMetadata")
    assert {:ok, %{"ttl" => 1.5}} = Schema.validate(task_metadata, %{"ttl" => 1.5})

    task = Schema.compile_protocol_definition!(@legacy_version, "Task")

    valid_task = %{
      "taskId" => "task-1",
      "status" => "working",
      "ttl" => nil,
      "pollInterval" => 0.5,
      "createdAt" => "2025-11-25T00:00:00Z",
      "lastUpdatedAt" => "2025-11-25T00:00:00.250Z"
    }

    assert {:ok, ^valid_task} = Schema.validate(task, valid_task)

    assert {:error, _error} =
             Schema.validate(task, %{valid_task | "createdAt" => "not-a-date"})

    blob = Schema.compile_protocol_definition!(@legacy_version, "BlobResourceContents")

    assert {:ok, _value} =
             Schema.validate(blob, %{"uri" => "file:///tmp/data", "blob" => "AA=="})

    assert {:error, _error} =
             Schema.validate(blob, %{"uri" => "file:///tmp/data", "blob" => "AA==="})

    assert {:error, _error} =
             Schema.validate(blob, %{"uri" => "not a URI", "blob" => "AA=="})

    template = Schema.compile_protocol_definition!(@legacy_version, "ResourceTemplate")

    assert {:ok, _value} =
             Schema.validate(template, %{"name" => "item", "uriTemplate" => "item://{id}"})

    assert {:error, _error} =
             Schema.validate(template, %{"name" => "item", "uriTemplate" => "item://{=id}"})

    subscribe = Schema.compile_protocol_definition!(@legacy_version, "SubscribeRequestParams")

    assert {:ok, %{"uri" => "item://one"}} =
             Schema.validate(subscribe, %{"uri" => "item://one"})

    assert {:error, _error} = Schema.validate(subscribe, %{"uri" => "item://{id}"})

    assert {:error, _error} = Schema.validate(subscribe, %{"uri" => "not a URI"})
  end

  test "2020-12 keywords and recursive local references are supported" do
    schema = %{
      "$defs" => %{
        "node" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "minLength" => 1},
            "child" => %{"$ref" => "#/$defs/node"}
          },
          "required" => ["name"],
          "unevaluatedProperties" => false
        }
      },
      "$ref" => "#/$defs/node"
    }

    assert {:ok, compiled} = Schema.compile(schema)

    assert {:ok, _value} =
             Schema.validate(compiled, %{"name" => "root", "child" => %{"name" => "leaf"}})

    assert {:error, error} =
             Schema.validate(compiled, %{
               "name" => "root",
               "child" => %{"name" => "", "extra" => true}
             })

    assert Enum.any?(error.violations, &(&1.instance_path == "#/child/name"))
    assert Enum.any?(error.violations, &(&1.keyword == "unevaluatedProperties"))
  end

  test "remote references fail closed unless an application resolver is explicit" do
    target = "https://schemas.example/value"

    schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"$ref" => target}},
      "required" => ["value"]
    }

    assert {:error, error} = Schema.compile(schema)
    assert error.phase == :compile

    resolver = fn
      ^target -> {:ok, %{"$id" => target, "type" => "integer"}}
      _other -> {:error, :not_found}
    end

    assert {:ok, compiled} = Schema.compile(schema, resolver: resolver)
    assert {:ok, %{"value" => 3}} = Schema.validate(compiled, %{"value" => 3})
    assert {:error, _error} = Schema.validate(compiled, %{"value" => "3"})

    boolean_target = "https://schemas.example/never"

    assert {:ok, compiled_boolean} =
             Schema.compile(%{"$ref" => boolean_target},
               resolver: fn ^boolean_target -> {:ok, false} end
             )

    assert {:error, _error} = Schema.validate(compiled_boolean, "rejected")
  end

  test "the opt-in HTTP resolver rejects insecure and non-allowlisted URLs before I/O" do
    opts = [allowed_hosts: ["schemas.example"]]

    assert {:error, {:restricted_url, "http://schemas.example/value"}} =
             HTTPResolver.resolve("http://schemas.example/value", opts)

    assert {:error, {:restricted_url, "https://other.example/value"}} =
             HTTPResolver.resolve("https://other.example/value", opts)

    for url <- [
          "https://user@schemas.example/value",
          "https://schemas.example:8443/value",
          "https://schemas.example/value#fragment"
        ] do
      assert {:error, {:restricted_url, ^url}} = HTTPResolver.resolve(url, opts)
    end

    assert {:error, :invalid_http_resolver_options} =
             HTTPResolver.resolve("https://schemas.example/value", [])
  end

  test "the opt-in HTTP resolver enforces redirect, media, and body bounds" do
    parent = self()

    requester = fn :get, url, opts ->
      send(parent, {:schema_request, url, opts})

      {:ok, 200, [{"content-type", "application/schema+json"}],
       JSON.encode!(%{"type" => "integer"})}
    end

    opts = [allowed_hosts: ["schemas.example"], requester: requester, max_body_bytes: 100]

    assert {:normal, %{"type" => "integer"}} =
             HTTPResolver.resolve("https://schemas.example/value", opts)

    assert_receive {:schema_request, "https://schemas.example/value", request_opts}
    assert request_opts[:http_options][:autoredirect] == false

    redirecting = fn _method, _url, _opts ->
      {:ok, 302, [{"content-type", "application/json"}], "{}"}
    end

    assert {:error, {:redirect_refused, 302}} =
             HTTPResolver.resolve("https://schemas.example/value",
               allowed_hosts: ["schemas.example"],
               requester: redirecting
             )

    oversized = fn _method, _url, _opts ->
      {:ok, 200, [{"content-type", "application/json"}], String.duplicate("x", 101)}
    end

    assert {:error, {:body_too_large, 101, 100}} =
             HTTPResolver.resolve("https://schemas.example/value",
               allowed_hosts: ["schemas.example"],
               max_body_bytes: 100,
               requester: oversized
             )

    mixed_case_media = fn _method, _url, _opts ->
      {:ok, 200, [{"Content-Type", "Application/Schema+JSON; Charset=UTF-8"}], "true"}
    end

    url = "https://schemas.example/boolean"

    assert {:normal, %{"$id" => ^url, "allOf" => [true]}} =
             HTTPResolver.resolve(url,
               allowed_hosts: ["schemas.example"],
               requester: mixed_case_media
             )
  end

  test "the opt-in HTTP resolver performs no implicit caching" do
    parent = self()
    url = "https://schemas.example/value"

    requester = fn :get, ^url, _opts ->
      send(parent, :schema_fetch)
      {:ok, 200, [{"content-type", "application/schema+json"}], "true"}
    end

    opts = [allowed_hosts: ["schemas.example"], requester: requester]

    assert {:normal, %{"$id" => ^url, "allOf" => [true]}} = HTTPResolver.resolve(url, opts)
    assert {:normal, %{"$id" => ^url, "allOf" => [true]}} = HTTPResolver.resolve(url, opts)
    assert_receive :schema_fetch
    assert_receive :schema_fetch
    refute_receive :schema_fetch
  end

  test "schema size, depth, reference bounds, and deterministic digests are enforced" do
    assert {:ok, digest} = Schema.digest(@object_schema)

    atom_key_schema = %{
      type: :object,
      properties: %{count: %{minimum: 1, type: :integer}},
      required: [:count],
      additionalProperties: false
    }

    assert {:ok, ^digest} = Schema.digest(atom_key_schema)

    assert {:error, error} = Schema.compile(@object_schema, max_schema_bytes: 10)
    assert error.message =~ "encoded bytes limit"

    assert {:error, error} = Schema.compile(@object_schema, max_depth: 1)
    assert error.message =~ "maximum nesting depth"

    references = %{
      "$defs" => %{"anything" => true},
      "allOf" => [
        %{"$ref" => "#/$defs/anything"},
        %{"$dynamicRef" => "#/$defs/anything"}
      ]
    }

    assert {:error, error} = Schema.compile(references, max_refs: 1)
    assert error.message =~ "references limit"

    assert {:error, error} = Schema.compile(@object_schema, max_resolved_resources: 0)
    assert error.message =~ "resolved resources limit must be a positive integer"
  end

  test "schema compilation and validation deadlines fail closed" do
    slow_resolver = fn
      "https://schemas.example/slow" ->
        Process.sleep(100)
        {:ok, true}

      _meta_schema ->
        {:error, :not_found}
    end

    assert {:error, compile_error} =
             Schema.compile(%{"$ref" => "https://schemas.example/slow"},
               resolver: slow_resolver,
               compile_timeout_ms: 5
             )

    assert compile_error.message == "JSON Schema compile exceeded 5ms"

    compiled = Schema.compile!(%{"type" => "array", "uniqueItems" => true})

    assert {:error, validation_error} =
             Schema.validate(compiled, Enum.to_list(1..100_000), validation_timeout_ms: 1)

    assert validation_error.message == "JSON Schema validation exceeded 1ms"
  end

  test "remote schemas share source, dialect, reference, and resource-count limits" do
    resolver = fn
      "https://schemas.example/one" ->
        {:ok, %{"$ref" => "https://schemas.example/two"}}

      "https://schemas.example/two" ->
        {:ok, true}

      "https://schemas.example/unsupported" ->
        {:ok,
         %{
           "$schema" => "https://json-schema.org/draft/2019-09/schema",
           "type" => "integer"
         }}

      "https://schemas.example/oversized" ->
        {:ok, %{"const" => String.duplicate("remote-secret", 100)}}

      "https://schemas.example/invalid" ->
        {:ok, %{"type" => "object", "required" => "not-an-array"}}
    end

    assert {:error, error} =
             Schema.compile(%{"$ref" => "https://schemas.example/one"},
               resolver: resolver,
               max_resolved_resources: 1
             )

    assert error.phase == :compile
    refute inspect(error) =~ "remote-secret"

    assert {:ok, compiled} =
             Schema.compile(%{"$ref" => "https://schemas.example/one"},
               resolver: resolver,
               max_resolved_resources: 2
             )

    assert {:ok, "anything"} = Schema.validate(compiled, "anything")

    assert {:error, error} =
             Schema.compile(%{"$ref" => "https://schemas.example/unsupported"},
               resolver: resolver
             )

    assert error.phase == :compile

    assert {:error, error} =
             Schema.compile(%{"$ref" => "https://schemas.example/oversized"},
               resolver: resolver,
               max_schema_bytes: 128
             )

    assert error.phase == :compile
    refute inspect(error) =~ "remote-secret"

    assert {:error, error} =
             Schema.compile(%{"$ref" => "https://schemas.example/invalid"},
               resolver: resolver
             )

    assert error.phase == :compile
  end

  test "violations are bounded and never reflect submitted values or unknown property names" do
    properties = Map.new(1..30, fn index -> {"p#{index}", %{"type" => "integer"}} end)
    value = Map.new(1..30, fn index -> {"p#{index}", "secret-#{index}"} end)

    assert {:error, bounded_error} =
             %{"type" => "object", "properties" => properties}
             |> Schema.compile!()
             |> Schema.validate(value)

    assert length(bounded_error.violations) == 20
    assert Enum.all?(bounded_error.violations, &(byte_size(&1.message) <= 300))
    refute inspect(bounded_error) =~ "secret-"

    numeric = Schema.compile!(%{"type" => "integer", "maximum" => 3})
    assert {:error, numeric_error} = Schema.validate(numeric, 987_654_321)
    refute inspect(numeric_error) =~ "987654321"

    closed_object =
      Schema.compile!(%{
        "type" => "object",
        "additionalProperties" => false
      })

    assert {:error, property_error} =
             Schema.validate(closed_object, %{"unknown-secret-property" => "secret-value"})

    refute inspect(property_error) =~ "unknown-secret-property"
    refute inspect(property_error) =~ "secret-value"

    unicode_property = String.duplicate("é", 200)

    unicode_schema =
      Schema.compile!(%{
        "type" => "object",
        "properties" => %{unicode_property => %{"type" => "integer"}}
      })

    assert {:error, unicode_error} =
             Schema.validate(unicode_schema, %{unicode_property => "wrong"})

    assert Enum.all?(unicode_error.violations, fn violation ->
             String.valid?(violation.instance_path) and byte_size(violation.instance_path) <= 300
           end)
  end

  test "tool inputs require object roots and arbitrary JSON structured outputs are validated" do
    assert_raise ArgumentError, ~r/input_schema.*type: "object"/, fn ->
      FastestMCP.server("invalid-input-root")
      |> FastestMCP.add_tool("bad", fn _args -> :ok end, input_schema: %{"type" => "array"})
    end

    server_name = "output-schema-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("valid", fn _args -> %{count: 2} end, output_schema: @object_schema)
      |> FastestMCP.add_tool(
        "scalar",
        fn _args ->
          ToolResult.new("ok", structured_content: "ok")
        end,
        output_schema: %{"type" => "string"}
      )
      |> FastestMCP.add_tool("wrong_type", fn _args -> %{count: "secret-result"} end,
        output_schema: @object_schema
      )
      |> FastestMCP.add_tool(
        "missing_structured",
        fn _args -> %{content: [%{type: "text", text: "only text"}]} end,
        output_schema: @object_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{count: 2} = FastestMCP.call_tool(server_name, "valid", %{})

    assert %{structuredContent: "ok"} = FastestMCP.call_tool(server_name, "scalar", %{})

    assert_raise Error, ~r/structuredContent.*does not match output_schema/, fn ->
      FastestMCP.call_tool(server_name, "wrong_type", %{})
    end

    try do
      FastestMCP.call_tool(server_name, "wrong_type", %{})
    rescue
      error in Error -> refute Exception.message(error) =~ "secret-result"
    end

    assert_raise Error, ~r/returned no structuredContent/, fn ->
      FastestMCP.call_tool(server_name, "missing_structured", %{})
    end
  end
end
