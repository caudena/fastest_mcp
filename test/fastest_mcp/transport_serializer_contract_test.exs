defmodule FastestMCP.TransportSerializerContractTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.ResultNormalizer
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
               "execution" => %{"taskSupport" => "optional"},
               "hint" => "keep",
               "tags" => ["text", "utility"],
               "version" => "2.0.0"
             }
           }

    refute Map.has_key?(tool, "execution")
    refute Map.has_key?(tool, "tags")
    refute Map.has_key?(tool, "version")

    template =
      Serializer.resource_template_metadata(%{
        uri_template: "memo://users/{id}",
        parameters: %{"id" => %{"type" => "string"}},
        execution: %{taskSupport: "required"}
      })

    assert get_in(template, ["_meta", "fastestmcp", "parameters"]) == %{
             "id" => %{"type" => "string"}
           }

    assert get_in(template, ["_meta", "fastestmcp", "execution"]) == %{
             "taskSupport" => "required"
           }

    refute Map.has_key?(template, "parameters")
    refute Map.has_key?(template, "execution")
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

  test "structuredContent is always an object on the wire" do
    assert_raise Error, ~r/structuredContent must be an object/, fn ->
      ResultNormalizer.normalize_tool(%{
        content: "invalid",
        structuredContent: ["not", "an", "object"]
      })
    end

    assert_raise Error, ~r/structuredContent must be an object/, fn ->
      Serializer.tool_result(%{content: "invalid", structuredContent: 42})
    end

    wrapped =
      Serializer.tool_result(["alpha", "beta"], %{
        output_schema: %{"type" => "array", "items" => %{"type" => "string"}}
      })

    assert wrapped["structuredContent"] == %{"result" => ["alpha", "beta"]}
    assert get_in(wrapped, ["_meta", "fastestmcp", "wrap_result"]) == true

    scalar = Serializer.tool_result(42)
    refute Map.has_key?(scalar, "structuredContent")
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
