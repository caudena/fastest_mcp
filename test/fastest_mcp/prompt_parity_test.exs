defmodule FastestMCP.PromptParityTest do
  use ExUnit.Case, async: false

  test "list_prompts exposes prompt arguments metadata" do
    server_name = "prompt-arguments-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
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

    assert {:ok, _pid} = FastestMCP.start_server(server)

    [prompt] = FastestMCP.list_prompts(server_name)

    assert prompt.name == "summarize"
    assert prompt.description == "Summarize a topic."

    assert [
             %{name: "topic", description: "The topic to summarize.", required: true},
             %{name: "tone", description: "Optional tone override", required: false}
           ] = prompt.arguments
  end

  test "list_prompts strips completion providers from prompt argument metadata" do
    server_name =
      "prompt-arguments-completion-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
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

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [prompt] = FastestMCP.list_prompts(server_name)
    [argument] = prompt.arguments

    assert %{name: "topic", description: "The topic to summarize.", required: true} = argument
    refute Map.has_key?(argument, :completion)
    refute Map.has_key?(argument, "completion")
  end

  test "render_prompt preserves description and meta when prompt returns a prompt result map" do
    server_name = "prompt-result-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("review", fn %{"subject" => subject}, _ctx ->
        %{
          messages: [
            %{role: "user", content: "Review #{subject}"},
            %{role: "assistant", content: "Looks good", meta: %{confidence: "high"}}
          ],
          description: "Review result",
          meta: %{source: "prompt"}
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

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
           } = FastestMCP.render_prompt(server_name, "review", %{"subject" => "docs"})
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
