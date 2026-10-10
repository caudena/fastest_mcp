defmodule FastestMCP.ToolResultTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Client
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "tool result helper validates and normalizes explicit result envelopes" do
    result =
      ToolResult.new(
        [
          %{type: "text", text: "Release checklist generated"},
          %{type: "text", text: "Warnings: 0"}
        ],
        structured_content: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
        meta: %{source: "helper"},
        is_error: false
      )

    assert %ToolResult{
             content: [
               %{type: "text", text: "Release checklist generated"},
               %{type: "text", text: "Warnings: 0"}
             ],
             structured_content: %{status: "ok", generated_at: "2025-11-05T12:30:45Z"},
             meta: %{source: "helper"},
             is_error: false
           } = result

    assert %{
             content: [
               %{type: "text", text: "Release checklist generated"},
               %{type: "text", text: "Warnings: 0"}
             ],
             structuredContent: %{status: "ok", generated_at: "2025-11-05T12:30:45Z"},
             meta: %{source: "helper"},
             isError: false
           } = ToolResult.to_map(result)

    assert_raise ArgumentError, ~r/requires content or structured_content/, fn ->
      ToolResult.new(nil)
    end

    assert_raise ArgumentError, ~r/meta must be a map/, fn ->
      ToolResult.new("bad", meta: [:invalid])
    end

    assert %ToolResult{structured_content: ["valid", 1, true]} =
             ToolResult.new("JSON values are supported", structured_content: ["valid", 1, true])

    assert %ToolResult{structured_content: nil, structured_content_present?: true} =
             null_result =
             ToolResult.new("JSON null is supported", structured_content: nil)

    assert %{content: "JSON null is supported", structuredContent: nil} =
             ToolResult.to_map(null_result)

    assert_raise ArgumentError, ~r/is_error must be a boolean/, fn ->
      ToolResult.new("bad", is_error: :invalid)
    end
  end

  test "tool handlers can return ToolResult and keep metadata over local and transport calls" do
    server_name = "tool-result-helper-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("report", fn _arguments, _ctx ->
      ToolResult.new(
        [
          %{type: "text", text: "Release checklist generated"},
          %{type: "text", text: "Warnings: 0"}
        ],
        structured_content: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
        meta: %{source: "helper"},
        is_error: false
      )
    end)
    |> start_server!()

    assert %ToolResult{
             content: [
               %{"type" => "text", "text" => "Release checklist generated"},
               %{"type" => "text", "text" => "Warnings: 0"}
             ],
             structured_content: %{status: "ok", generated_at: "2025-11-05T12:30:45Z"},
             meta: %{source: "helper"},
             is_error: false
           } = FastestMCP.call_tool!(server_name, "report", %{})

    assert %{
             "content" => [
               %{"type" => "text", "text" => "Release checklist generated"},
               %{"type" => "text", "text" => "Warnings: 0"}
             ],
             "structuredContent" => %{
               "status" => "ok",
               "generated_at" => "2025-11-05T12:30:45Z"
             },
             "_meta" => %{"source" => "helper"},
             "isError" => false
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "report", "arguments" => %{}}
             })
  end

  test "connected client returns ToolResult for explicit and derived envelopes" do
    server_name = "tool-result-client-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("report", fn _arguments, _ctx ->
      ToolResult.new(
        [%{type: "text", text: "Release checklist generated"}],
        structured_content: %{status: "ok"},
        meta: %{source: "helper"}
      )
    end)
    |> FastestMCP.add_tool("mirror", fn _arguments, _ctx ->
      ToolResult.new(nil, structured_content: %{message: "hi"})
    end)
    |> FastestMCP.add_tool("explicit_success_mirror", fn _arguments, _ctx ->
      ToolResult.new(nil, structured_content: %{message: "explicit"}, is_error: false)
    end)
    |> FastestMCP.add_tool("structured_error", fn _arguments, _ctx ->
      ToolResult.new(nil, structured_content: %{reason: "boom"}, is_error: true)
    end)
    |> start_server!()

    client = connect_http_client!(server_name)

    assert %{
             raw: %{
               "content" => [%{"type" => "text", "text" => "Release checklist generated"}],
               "structuredContent" => %{"status" => "ok"},
               "_meta" => %{"source" => "helper"}
             }
           } = Client.call_tool!(client, "report", %{})

    assert %{structured_content: %{"message" => "hi"}} = Client.call_tool!(client, "mirror", %{})

    assert %{structured_content: %{"message" => "explicit"}} =
             Client.call_tool!(client, "explicit_success_mirror", %{})

    assert %{
             raw: %{
               "content" => [%{"type" => "text"}],
               "structuredContent" => %{"reason" => "boom"},
               "isError" => true
             }
           } = Client.call_tool!(client, "structured_error", %{})
  end

  test "tool return values normalize explicit content blocks and preserve plain lists" do
    server_name = unique_name("tool-returns")
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("text_block", fn _args, _ctx ->
        ToolResult.new(%{type: "text", text: "Direct text content"})
      end)
      |> FastestMCP.add_tool("mixed_content", fn _args, _ctx ->
        ToolResult.new([
          %{type: "text", text: "First block"},
          %{type: "image", data: Base.encode64(image_bytes), mimeType: "image/png"},
          %{"key" => "value"},
          "Fourth block"
        ])
      end)
      |> FastestMCP.add_tool("plain_list", fn _args, _ctx -> ["apple", "banana", "cherry"] end)
    )

    assert %{content: [%{"type" => "text", "text" => "Direct text content"}]} =
             FastestMCP.call_tool!(server_name, "text_block", %{})

    assert %{
             content: [
               %{"type" => "text", "text" => "First block"},
               %{"type" => "image", "data" => encoded_image, "mimeType" => "image/png"},
               %{"type" => "text", "text" => encoded_map},
               %{"type" => "text", "text" => "Fourth block"}
             ]
           } = FastestMCP.call_tool!(server_name, "mixed_content", %{})

    assert Base.decode64!(encoded_image) == image_bytes
    assert JSON.decode!(encoded_map) == %{"key" => "value"}

    assert ["apple", "banana", "cherry"] == FastestMCP.call_tool!(server_name, "plain_list", %{})
  end

  test "tool return values normalize transport-unsafe scalars and explicit envelopes" do
    server_name = unique_name("tool-scalars")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("tuple_value", fn _args, _ctx -> {42, "hello", true} end)
      |> FastestMCP.add_tool("datetime_value", fn _args, _ctx -> ~U[2025-11-05 12:30:45Z] end)
      |> FastestMCP.add_tool("range_value", fn _args, _ctx -> 1..3 end)
      |> FastestMCP.add_tool("explicit_envelope", fn _args, _ctx ->
        ToolResult.from(%{
          content: [%{type: "text", text: "hello"}],
          structuredContent: %{count: 2, at: ~U[2025-11-05 12:30:45Z]}
        })
      end)
    )

    assert [42, "hello", true] == FastestMCP.call_tool!(server_name, "tuple_value", %{})
    assert "2025-11-05T12:30:45Z" == FastestMCP.call_tool!(server_name, "datetime_value", %{})
    assert [1, 2, 3] == FastestMCP.call_tool!(server_name, "range_value", %{})

    assert %{
             content: [%{"type" => "text", "text" => "hello"}],
             structured_content: %{count: 2, at: "2025-11-05T12:30:45Z"}
           } = FastestMCP.call_tool!(server_name, "explicit_envelope", %{})
  end

  test "task results keep normalized tool return values through the task protocol" do
    server_name = unique_name("tool-task-returns")
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 4, 5, 6, 7>>

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "image_block",
        fn _args, _ctx ->
          ToolResult.new(%{type: "image", data: image_bytes, mimeType: "image/png"})
        end,
        task: true
      )
    )

    task = FastestMCP.call_tool!(server_name, "image_block", %{}, task: true)
    assert %BackgroundTask{} = task

    assert %{content: [%{"type" => "image", "data" => encoded_image, "mimeType" => "image/png"}]} =
             FastestMCP.await_task!(task, 1_000)

    assert Base.decode64!(encoded_image) == image_bytes

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "task-session",
        task_request: true,
        payload: %{"name" => "image_block", "arguments" => %{}},
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]

    assert %{
             status: :completed
           } = await_task_status(server_name, task_id, :completed, session_id: "task-session")

    assert %{
             "content" => [
               %{"type" => "image", "data" => transport_image, "mimeType" => "image/png"}
             ],
             "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tasks/result",
               transport: :stdio,
               session_id: "task-session",
               payload: %{"taskId" => task_id},
               session_id_provided?: true
             })

    assert Base.decode64!(transport_image) == image_bytes
  end

  test "object output schemas preserve structured results across immediate and task calls" do
    server_name = unique_name("tool-output-schema")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("list_values", fn _args, _ctx -> %{values: ["alpha", "beta"]} end,
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "values" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["values"]
        },
        task: true
      )
    )

    client =
      connect_http_client!(server_name,
        client_info: %{"name" => "wrap-result-client", "version" => "1.0.0"}
      )

    assert %{
             tools: [
               %{
                 "name" => "list_values",
                 "outputSchema" => %{
                   "type" => "object",
                   "properties" => %{
                     "values" => %{"type" => "array", "items" => %{"type" => "string"}}
                   },
                   "required" => ["values"]
                 }
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })

    assert %{
             "structuredContent" => %{"values" => ["alpha", "beta"]}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "list_values", "arguments" => %{}}
             })

    assert %{structured_content: %{"values" => ["alpha", "beta"]}} =
             Client.call_tool!(client, "list_values", %{})

    task = Client.call_tool_task!(client, "list_values", %{}, task: true)
    task_id = task.task_id

    assert %{
             "structuredContent" => %{"values" => ["alpha", "beta"]},
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
             }
           } = Client.Task.result!(task).raw
  end

  test "an error result needs no structured content under an output schema" do
    server_name = unique_name("tool-output-schema-error")

    output_schema = %{
      "type" => "object",
      "properties" => %{"title" => %{"type" => "string"}},
      "required" => ["title"]
    }

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "find_note",
        fn %{"id" => id}, _ctx -> ToolResult.new("No note has id #{id}.", is_error: true) end,
        input_schema: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        },
        output_schema: output_schema
      )
      |> FastestMCP.add_tool(
        "mistyped_error",
        fn _args, _ctx ->
          ToolResult.new("No note.", is_error: true, structured_content: %{title: 1})
        end,
        output_schema: output_schema
      )
    )

    assert %ToolResult{is_error: true} =
             FastestMCP.call_tool!(server_name, "find_note", %{"id" => "7"})

    wire =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        payload: %{"name" => "find_note", "arguments" => %{"id" => "7"}}
      })

    assert %{"isError" => true, "content" => [%{"text" => "No note has id 7."}]} = wire
    refute Map.has_key?(wire, "structuredContent")

    client = connect!({:in_process, server_name})
    assert %{is_error: true} = Client.call_tool!(client, "find_note", %{"id" => "7"})

    # Structured content that an error result does carry must still match.
    assert {:error, %FastestMCP.Error{code: :internal_error}} =
             FastestMCP.call_tool(server_name, "mistyped_error")
  end

  test "task results keep the executed tool descriptor after version visibility changes" do
    server_name = unique_name("tool-task-version-descriptor")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> %{values: ["alpha"]} end,
        version: "1.0.0",
        task: true,
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "values" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["values"]
        }
      )
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> %{value: 2} end,
        version: "2.0.0",
        task: true,
        output_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        }
      )
    )

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "task-session",
        task_request: true,
        payload: %{
          "name" => "calc",
          "arguments" => %{},
          "_meta" => %{"fastestmcp" => %{"version" => "1.0.0"}}
        },
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]

    assert %{status: :completed} =
             await_task_status(server_name, task_id, :completed, session_id: "task-session")

    :ok =
      FastestMCP.disable_components!(server_name,
        names: ["calc"],
        version: %{eq: "1.0.0"},
        components: [:tool]
      )

    assert %{
             "content" => [%{"type" => "text"}],
             "structuredContent" => %{"values" => ["alpha"]},
             "_meta" => %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
             }
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tasks/result",
               transport: :stdio,
               session_id: "task-session",
               payload: %{"taskId" => task_id},
               session_id_provided?: true
             })
  end

  test "malformed tool content fails local and wire calls alike" do
    server_name = unique_name("tool-malformed-content")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("unknown_block", fn _args, _ctx ->
        ToolResult.new([%{type: "vendor/unknown"}])
      end)
    )

    assert {:error, %FastestMCP.Error{code: :internal_error} = local} =
             FastestMCP.call_tool(server_name, "unknown_block", %{})

    assert local.message =~ "content block has unsupported type"

    assert {:error, %FastestMCP.Error{code: :internal_error, message: wire_message}} =
             Engine.dispatch(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "unknown_block", "arguments" => %{}}
             })

    assert wire_message == local.message
  end

  test "a result that has no JSON form fails with a clear error in process and over HTTP" do
    server_name = unique_name("tool-not-json")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("stream_notes", fn _args, _ctx -> Stream.map(1..3, & &1) end)
      |> FastestMCP.add_tool("notify_me", fn _args, _ctx -> %{reply_to: self()} end)
      |> FastestMCP.add_resource("notes://stream", fn _args, _ctx ->
        %{notes: Stream.map(1..3, & &1)}
      end)
    )

    stream_message = "a stream cannot be encoded as JSON; call Enum.to_list/1 on it first"

    assert {:error, %FastestMCP.Error{code: :internal_error, message: ^stream_message}} =
             FastestMCP.call_tool(server_name, "stream_notes")

    assert {:error, %FastestMCP.Error{code: :internal_error, message: ^stream_message}} =
             FastestMCP.read_resource(server_name, "notes://stream")

    assert {:error, %FastestMCP.Error{message: "a PID cannot be encoded as JSON"}} =
             FastestMCP.call_tool(server_name, "notify_me")

    modern =
      ProtocolTest.modern_http_request(server_name, 1, "tools/call", %{"name" => "stream_notes"},
        headers: [{"mcp-name", "stream_notes"}]
      )

    assert %{"error" => %{"code" => -32_603, "message" => ^stream_message}} =
             JSON.decode!(modern.resp_body)

    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    legacy =
      ProtocolTest.http_request(server_name, session_id, 2, "resources/read", %{
        "uri" => "notes://stream"
      })

    assert %{"error" => %{"code" => -32_603, "message" => ^stream_message}} =
             JSON.decode!(legacy.resp_body)
  end

  defp connect_http_client!(server_name, opts \\ []) do
    %{url: url} = start_http!(server_name)
    client = connect!(url, Keyword.put(opts, :protocol_version, "2025-11-25"))
    client
  end
end
