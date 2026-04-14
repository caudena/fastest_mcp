defmodule FastestMCP.PromptHelpersTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Prompts.Message
  alias FastestMCP.Prompts.Result
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "prompt helpers normalize strings roles metadata and JSON content" do
    message = Message.new(%{topic: "docs"}, role: :assistant, meta: %{source: "test"})

    assert %{
             role: "assistant",
             content: %{type: "text", text: "{\"topic\":\"docs\"}"},
             meta: %{source: "test"}
           } = Message.to_map(message)

    result =
      Result.new(
        [
          Message.new("Review this diff"),
          Message.new("Done.", role: :assistant)
        ],
        description: "Review result",
        meta: %{kind: "demo"}
      )

    assert %{description: "Review result", meta: %{kind: "demo"}, messages: [%{}, %{}]} =
             Result.to_map(result)
  end

  test "prompt result helper rejects bare single messages" do
    assert_raise ArgumentError, ~r/bare message/, fn ->
      Result.new(Message.new("not wrapped"))
    end
  end

  test "prompt handlers can return Prompt helpers and transport output stays normalized" do
    server_name = "prompt-helpers-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("review", fn _arguments, _ctx ->
        Result.new(
          [
            Message.new("Review this file"),
            Message.new(%{type: "resource", resource: %{uri: "file:///tmp/report.md"}},
              role: :assistant
            )
          ],
          description: "Prompt helper result",
          meta: %{source: "helper"}
        )
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             description: "Prompt helper result",
             meta: %{source: "helper"},
             messages: [
               %{role: "user", content: %{type: "text", text: "Review this file"}},
               %{
                 role: "assistant",
                 content: %{type: "resource", resource: %{uri: "file:///tmp/report.md"}}
               }
             ]
           } = FastestMCP.render_prompt(server_name, "review", %{})

    assert %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "Review this file"}
               },
               %{
                 "role" => "assistant",
                 "content" => %{
                   "type" => "resource",
                   "resource" => %{"uri" => "file:///tmp/report.md"}
                 }
               }
             ],
             "description" => "Prompt helper result",
             "meta" => %{"source" => "helper"}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "prompts/get",
               transport: :stdio,
               payload: %{"name" => "review", "arguments" => %{}}
             })
  end
end
