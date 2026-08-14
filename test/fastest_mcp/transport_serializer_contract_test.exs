defmodule FastestMCP.TransportSerializerContractTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.ResultNormalizer
  alias FastestMCP.Schema
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.Serializer

  test "component extensions stay under _meta.fastestmcp" do
    tool =
      Serializer.tool_metadata(%{
        name: "echo",
        description: "Echo input",
        input_schema: %{"type" => "object"},
        tags: MapSet.new(["utility", "text"]),
        version: "2.0.0",
        execution: %{taskSupport: "optional"},
        meta: %{
          "vendor" => %{"stable" => true},
          "fastestmcp" => %{"hint" => "keep", "_private" => "drop"}
        }
      })

    assert tool["_meta"] == %{
             "vendor" => %{"stable" => true},
             "fastestmcp" => %{
               "hint" => "keep",
               "tags" => ["text", "utility"],
               "version" => "2.0.0"
             }
           }

    refute Map.has_key?(tool, "tags")
    refute Map.has_key?(tool, "version")
    assert tool["execution"] == %{"taskSupport" => "optional"}

    template =
      Serializer.resource_template_metadata(%{
        uri_template: "memo://users/{id}",
        parameters: %{"id" => %{"type" => "string"}},
        execution: %{taskSupport: "required"}
      })

    assert get_in(template, ["_meta", "fastestmcp", "parameters"]) == %{
             "id" => %{"type" => "string"}
           }

    refute Map.has_key?(template, "execution")
    refute Map.has_key?(template, "parameters")
    refute get_in(template, ["_meta", "fastestmcp", "execution"])
  end

  test "content metadata is preserved and resource links use direct protocol fields" do
    result =
      Serializer.tool_result(%{
        content: [
          %{
            type: :text,
            text: "ready",
            annotations: %{audience: ["user"]},
            meta: %{trace: "text-1"}
          },
          %{
            type: "resource",
            resource: %{
              uri: "memo://embedded",
              text: "embedded",
              _meta: %{cache: "hit"}
            },
            _meta: %{trace: "resource-1"}
          },
          %{
            type: "resource_link",
            uri: "memo://linked",
            name: "Linked memo",
            mime_type: "text/plain",
            size: 12,
            annotations: %{audience: ["assistant"]},
            meta: %{trace: "link-1"}
          }
        ],
        structured_content: %{status: "ok"},
        _meta: %{request: "request-1"}
      })

    assert result["_meta"] == %{"request" => "request-1"}

    assert [text, embedded, link] = result["content"]
    assert text["_meta"] == %{"trace" => "text-1"}
    assert text["annotations"] == %{"audience" => ["user"]}
    assert embedded["_meta"] == %{"trace" => "resource-1"}
    assert embedded["resource"]["_meta"] == %{"cache" => "hit"}

    assert link == %{
             "type" => "resource_link",
             "uri" => "memo://linked",
             "name" => "Linked memo",
             "mimeType" => "text/plain",
             "size" => 12,
             "annotations" => %{"audience" => ["assistant"]},
             "_meta" => %{"trace" => "link-1"}
           }

    refute Map.has_key?(link, "resourceLink")
  end

  test "result and content metadata use _meta for resources and prompts" do
    assert %{
             "_meta" => %{"source" => "resource"},
             "contents" => [
               %{
                 "uri" => "memo://bundle",
                 "mimeType" => "text/plain",
                 "text" => "hello",
                 "_meta" => %{"slot" => "first"}
               }
             ]
           } =
             Serializer.resource_result("memo://bundle", nil, %{
               contents: [
                 %{content: "hello", mime_type: "text/plain", meta: %{slot: "first"}}
               ],
               _meta: %{source: "resource"}
             })

    assert %{
             "_meta" => %{"source" => "prompt"},
             "messages" => [
               %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "done"},
                 "_meta" => %{"confidence" => "high"}
               }
             ]
           } =
             Serializer.prompt_result(%{
               messages: [
                 %{role: "assistant", content: "done", _meta: %{confidence: "high"}}
               ],
               _meta: %{source: "prompt"}
             })
  end

  test "structuredContent preserves JSON values while the protocol profile owns wire constraints" do
    assert %{structuredContent: ["not", "an", "object"]} =
             ResultNormalizer.normalize_tool(%{
               content: "valid text",
               structuredContent: ["not", "an", "object"]
             })

    assert %{"structuredContent" => 42} =
             Serializer.tool_result(
               %{content: "valid text", structuredContent: 42},
               nil,
               protocol_version: "2026-07-28"
             )

    assert %{"structuredContent" => nil} =
             Serializer.tool_result(
               %{content: "valid text", structuredContent: nil},
               nil,
               protocol_version: "2026-07-28"
             )

    assert %{"structuredContent" => nil} =
             Serializer.tool_result(nil, nil, protocol_version: "2026-07-28")

    modern_list =
      Serializer.tool_result(["alpha", "beta"], nil, protocol_version: "2026-07-28")

    assert modern_list["structuredContent"] == ["alpha", "beta"]

    modern_scalar = Serializer.tool_result(42, nil, protocol_version: "2026-07-28")
    assert modern_scalar["structuredContent"] == 42

    legacy_list =
      Serializer.tool_result(["alpha", "beta"], nil, protocol_version: "2025-11-25")

    refute Map.has_key?(legacy_list, "structuredContent")

    legacy_scalar = Serializer.tool_result(42, nil, protocol_version: "2025-11-25")
    refute Map.has_key?(legacy_scalar, "structuredContent")

    array_result = %{
      "content" => [],
      "structuredContent" => ["alpha", "beta"]
    }

    legacy_envelope = %{"jsonrpc" => "2.0", "id" => "call-1", "result" => array_result}

    assert {:error, %Schema.Error{}} =
             Schema.validate_protocol(
               "2025-11-25",
               :server_to_client,
               :response,
               "tools/call",
               legacy_envelope
             )

    modern_envelope =
      put_in(legacy_envelope, ["result"], Map.put(array_result, "resultType", "complete"))

    assert {:ok, ^modern_envelope} =
             Schema.validate_protocol(
               "2026-07-28",
               :server_to_client,
               :response,
               "tools/call",
               modern_envelope
             )
  end

  test "tool metadata exposes arbitrary output schemas and no legacy task hints only in modern" do
    tool = %{
      name: "scalar",
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "string"},
      execution: %{taskSupport: "required"}
    }

    modern = Serializer.tool_metadata(tool, protocol_version: "2026-07-28")
    assert modern["outputSchema"] == %{"type" => "string"}
    refute Map.has_key?(modern, "execution")

    legacy = Serializer.tool_metadata(tool, protocol_version: "2025-11-25")
    refute Map.has_key?(legacy, "outputSchema")
    assert legacy["execution"] == %{"taskSupport" => "required"}

    explicit_scalar = %{content: "ok", structuredContent: "ok"}

    assert Serializer.tool_result(explicit_scalar, nil, protocol_version: "2026-07-28")[
             "structuredContent"
           ] == "ok"

    refute Map.has_key?(
             Serializer.tool_result(explicit_scalar, nil, protocol_version: "2025-11-25"),
             "structuredContent"
           )
  end

  test "media and embedded blobs are base64-encoded and valid base64 is preserved" do
    result =
      Serializer.tool_result(%{
        content: [
          %{type: "image", data: "plain image bytes", mimeType: "image/png"},
          %{
            type: "resource",
            resource: %{uri: "memo://blob", blob: "plain blob bytes"}
          }
        ]
      })

    assert [image, embedded] = result["content"]
    assert Base.decode64!(image["data"]) == "plain image bytes"
    assert Base.decode64!(embedded["resource"]["blob"]) == "plain blob bytes"

    encoded = Base.encode64("already encoded")

    assert %{"content" => [%{"data" => ^encoded}]} =
             Serializer.tool_result(%{
               content: [%{type: "audio", data: encoded, mimeType: "audio/wav"}]
             })
  end

  test "malformed explicit tool results fail deterministically" do
    for result <- [
          %{content: nil},
          %{content: [], isError: nil},
          %{content: [], isError: "false"}
        ] do
      assert_raise Error, fn -> Serializer.tool_result(result) end
    end

    assert_raise Error, ~r/content block has unsupported type/, fn ->
      Serializer.tool_result(%{content: [%{type: "vendor/unknown"}]})
    end

    assert_raise Error, ~r/text must be a string/, fn ->
      Serializer.tool_result(%{content: [%{type: "text", text: 42}]})
    end

    assert_raise Error, ~r/media and blob data must be binary/, fn ->
      Serializer.tool_result(%{
        content: [%{type: "image", data: 42, mimeType: "image/png"}]
      })
    end

    assert_raise Error, ~r/embedded resource content requires an object/, fn ->
      Serializer.tool_result(%{content: [%{type: "resource", resource: nil}]})
    end

    assert_raise Error, ~r/duplicate normalized _meta key/, fn ->
      Serializer.tool_result(%{
        content: [],
        _meta: %{"trace" => "string", trace: "atom"}
      })
    end
  end

  test "task extensions stay under _meta.fastestmcp and absent cursors are omitted" do
    task = %{
      id: "task-1",
      status: :input_required,
      submitted_at: 1_700_000_000_000,
      updated_at: 1_700_000_000_100,
      ttl_ms: 60_000,
      poll_interval_ms: 500,
      elicitation: %{
        request_id: "request-1",
        message: "Choose",
        requested_schema: %{"type" => "string"}
      }
    }

    payload = TaskWire.task(task)

    refute Map.has_key?(payload, :elicitation)

    assert get_in(payload, [:_meta, "fastestmcp", "elicitation"]) == %{
             requestId: "request-1",
             message: "Choose",
             requestedSchema: %{"type" => "string"}
           }

    assert %{tasks: [^payload]} = TaskWire.task_list(%{tasks: [task], next_cursor: nil})
    refute Map.has_key?(TaskWire.task_list(%{tasks: [task], next_cursor: nil}), :nextCursor)
  end
end
