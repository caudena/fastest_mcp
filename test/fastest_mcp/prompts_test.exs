defmodule FastestMCP.PromptsTest do
  use FastestMCP.Case, async: true

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

    FastestMCP.server(server_name)
    |> FastestMCP.add_prompt("review", fn _arguments, _ctx ->
      Result.new(
        [
          Message.new("Review this file"),
          Message.new(
            %{
              type: "resource",
              resource: %{uri: "file:///tmp/report.md", text: "# Report"}
            },
            role: :assistant
          )
        ],
        description: "Prompt helper result",
        meta: %{source: "helper"}
      )
    end)
    |> start_server!()

    assert %{
             description: "Prompt helper result",
             meta: %{source: "helper"},
             messages: [
               %{role: "user", content: %{type: "text", text: "Review this file"}},
               %{
                 role: "assistant",
                 content: %{
                   type: "resource",
                   resource: %{uri: "file:///tmp/report.md", text: "# Report"}
                 }
               }
             ]
           } = FastestMCP.render_prompt!(server_name, "review", %{})

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
                   "resource" => %{"uri" => "file:///tmp/report.md", "text" => "# Report"}
                 }
               }
             ],
             "description" => "Prompt helper result",
             "_meta" => %{"source" => "helper"}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "prompts/get",
               transport: :stdio,
               payload: %{"name" => "review", "arguments" => %{}}
             })
  end

  test "render_prompt preserves canonical _meta when a prompt returns a result map" do
    server_name = unique_name("prompt-result")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("review", fn %{"subject" => subject}, _ctx ->
        Result.from(%{
          messages: [
            %{role: "user", content: "Review #{subject}"},
            %{role: "assistant", content: "Looks good", _meta: %{confidence: "high"}}
          ],
          description: "Review result",
          _meta: %{source: "prompt"}
        })
      end)
    )

    assert %{
             description: "Review result",
             meta: %{source: "prompt"},
             messages: [
               %{role: "user", content: %{type: "text", text: "Review docs"}},
               %{
                 role: "assistant",
                 content: %{type: "text", text: "Looks good"},
                 meta: %{confidence: "high"}
               }
             ]
           } = FastestMCP.render_prompt!(server_name, "review", %{"subject" => "docs"})
  end

  test "list_prompts exposes prompt arguments metadata" do
    server_name = unique_name("prompt-arguments")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt(
        "summarize",
        fn %{"topic" => topic}, _ctx -> "Summary for #{topic}" end,
        description: "Summarize a topic.",
        arguments: [
          %{name: "topic", description: "The topic to summarize.", required: true},
          {"tone", "Optional tone override"}
        ]
      )
    )

    [prompt] = FastestMCP.list_prompts!(server_name)

    assert prompt.name == "summarize"
    assert prompt.description == "Summarize a topic."

    assert [
             %{name: "topic", description: "The topic to summarize.", required: true},
             %{name: "tone", description: "Optional tone override", required: false}
           ] = prompt.arguments
  end

  test "list_prompts strips completion providers from prompt argument metadata" do
    server_name = unique_name("prompt-arguments-completion")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt(
        "summarize",
        fn %{"topic" => topic}, _ctx -> "Summary for #{topic}" end,
        arguments: [
          %{
            name: "topic",
            description: "The topic to summarize.",
            required: true,
            completion: fn _partial -> ["docs", "release-notes"] end
          }
        ]
      )
    )

    [prompt] = FastestMCP.list_prompts!(server_name)
    [argument] = prompt.arguments

    assert %{name: "topic", description: "The topic to summarize.", required: true} = argument
    refute Map.has_key?(argument, :completion)
    refute Map.has_key?(argument, "completion")
  end

  test "invalid prompt argument configuration raises" do
    assert_raise ArgumentError,
                 "prompt argument name must be a non-empty string, got nil",
                 fn ->
                   FastestMCP.server("bad-prompt")
                   |> FastestMCP.add_prompt("bad", fn _arguments, _ctx -> "nope" end,
                     arguments: [%{description: "Missing name"}]
                   )
                 end
  end
end
