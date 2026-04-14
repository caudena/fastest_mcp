defmodule FastestMCP.ToolReturnTypeParityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Client
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "tool return values normalize explicit content blocks and preserve plain lists" do
    server_name = "tool-returns-" <> Integer.to_string(System.unique_integer([:positive]))
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("text_block", fn _args, _ctx ->
        %{type: "text", text: "Direct text content"}
      end)
      |> FastestMCP.add_tool("mixed_content", fn _args, _ctx ->
        [
          %{type: "text", text: "First block"},
          %{type: "image", data: Base.encode64(image_bytes), mimeType: "image/png"},
          %{"key" => "value"},
          "Fourth block"
        ]
      end)
      |> FastestMCP.add_tool("plain_list", fn _args, _ctx -> ["apple", "banana", "cherry"] end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{content: [%{type: "text", text: "Direct text content"}]} =
             FastestMCP.call_tool(server_name, "text_block", %{})

    assert %{
             content: [
               %{type: "text", text: "First block"},
               %{type: "image", data: encoded_image, mimeType: "image/png"},
               %{type: "text", text: encoded_map},
               %{type: "text", text: "Fourth block"}
             ]
           } = FastestMCP.call_tool(server_name, "mixed_content", %{})

    assert Base.decode64!(encoded_image) == image_bytes
    assert Jason.decode!(encoded_map) == %{"key" => "value"}

    assert ["apple", "banana", "cherry"] == FastestMCP.call_tool(server_name, "plain_list", %{})
  end

  test "tool return values normalize transport-unsafe scalars and explicit envelopes" do
    server_name = "tool-scalars-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("tuple_value", fn _args, _ctx -> {42, "hello", true} end)
      |> FastestMCP.add_tool("datetime_value", fn _args, _ctx -> ~U[2025-11-05 12:30:45Z] end)
      |> FastestMCP.add_tool("explicit_envelope", fn _args, _ctx ->
        %{
          content: [%{type: "text", text: "hello"}],
          structuredContent: %{count: 2, at: ~U[2025-11-05 12:30:45Z]}
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert [42, "hello", true] == FastestMCP.call_tool(server_name, "tuple_value", %{})
    assert "2025-11-05T12:30:45Z" == FastestMCP.call_tool(server_name, "datetime_value", %{})

    assert %{
             content: [%{type: "text", text: "hello"}],
             structuredContent: %{count: 2, at: "2025-11-05T12:30:45Z"}
           } = FastestMCP.call_tool(server_name, "explicit_envelope", %{})
  end

  test "task results keep normalized tool return values through the task protocol" do
    server_name = "tool-task-returns-" <> Integer.to_string(System.unique_integer([:positive]))
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 4, 5, 6, 7>>

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "image_block",
        fn _args, _ctx ->
          %{type: "image", data: image_bytes, mimeType: "image/png"}
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    task = FastestMCP.call_tool(server_name, "image_block", %{}, task: true)
    assert %BackgroundTask{} = task

    assert %{content: [%{type: "image", data: encoded_image, mimeType: "image/png"}]} =
             FastestMCP.await_task(task, 1_000)

    assert Base.decode64!(encoded_image) == image_bytes

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "task-session",
        task_request: true,
        payload: %{"name" => "image_block", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    assert %{
             status: :completed
           } = wait_for_task_completion(server_name, task_id, "task-session")

    assert %{
             "content" => [
               %{"type" => "image", "data" => transport_image, "mimeType" => "image/png"}
             ],
             :_meta => %{"io.modelcontextprotocol/related-task" => %{taskId: ^task_id}}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tasks/result",
               transport: :stdio,
               session_id: "task-session",
               payload: %{"taskId" => task_id},
               request_metadata: %{session_id_provided: true}
             })

    assert Base.decode64!(transport_image) == image_bytes
  end

  test "non-object output schemas advertise wrap-result metadata and preserve the envelope" do
    server_name =
      "tool-wrap-result-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("list_values", fn _args, _ctx -> ["alpha", "beta"] end,
        output_schema: %{
          "type" => "array",
          "items" => %{"type" => "string"}
        },
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        client_info: %{"name" => "wrap-result-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Process.alive?(bandit), do: Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end)

    assert %{
             tools: [
               %{
                 "name" => "list_values",
                 "outputSchema" => %{
                   "type" => "array",
                   "items" => %{"type" => "string"},
                   "x-fastestmcp-wrap-result" => true
                 }
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })

    assert %{
             "structuredContent" => %{"result" => ["alpha", "beta"]},
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "list_values", "arguments" => %{}}
             })

    assert %{
             "content" => [%{"type" => "text"}],
             "structuredContent" => %{"result" => ["alpha", "beta"]},
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
           } = Client.call_tool(client, "list_values", %{})

    task = Client.call_tool(client, "list_values", %{}, task: true)

    assert %{
             "content" => [%{"type" => "text"}],
             "structuredContent" => %{"result" => ["alpha", "beta"]},
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
           } = Client.task_result(client, task.task_id)
  end

  test "task results keep the executed tool descriptor after version visibility changes" do
    server_name =
      "tool-task-version-descriptor-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("calc", fn _args, _ctx -> ["alpha"] end,
        version: "1.0.0",
        task: true,
        output_schema: %{
          "type" => "array",
          "items" => %{"type" => "string"}
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

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

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
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    assert %{status: :completed} = wait_for_task_completion(server_name, task_id, "task-session")

    :ok =
      FastestMCP.disable_components(server_name,
        names: ["calc"],
        version: %{eq: "1.0.0"},
        components: [:tool]
      )

    assert %{
             "content" => [%{"type" => "text"}],
             "structuredContent" => %{"result" => ["alpha"]},
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}},
             :_meta => %{"io.modelcontextprotocol/related-task" => %{taskId: ^task_id}}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tasks/result",
               transport: :stdio,
               session_id: "task-session",
               payload: %{"taskId" => task_id},
               request_metadata: %{session_id_provided: true}
             })
  end

  defp wait_for_task_completion(server_name, task_id, session_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_task_completion(server_name, task_id, session_id, deadline)
  end

  defp do_wait_for_task_completion(server_name, task_id, session_id, deadline) do
    task = FastestMCP.fetch_task(server_name, task_id, session_id: session_id)

    cond do
      task.status == :completed ->
        task

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for task #{inspect(task_id)} to complete")

      true ->
        Process.sleep(10)
        do_wait_for_task_completion(server_name, task_id, session_id, deadline)
    end
  end
end
