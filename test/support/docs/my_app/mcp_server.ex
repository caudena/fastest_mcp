# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule

  alias MyApp.Notes

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool(
      "add_note",
      fn %{"title" => title, "body" => body}, _ctx -> Notes.create(title, body) end,
      description: "Save a note.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "A short title"},
          "body" => %{"type" => "string", "description" => "The text of the note"}
        },
        "required" => ["title", "body"]
      }
    )
    |> FastestMCP.add_tool(
      "search_notes",
      fn %{"query" => query}, _ctx -> %{notes: Notes.search(query)} end,
      description: "Find the notes that contain a word or phrase.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "The word or phrase to find"}
        },
        "required" => ["query"]
      }
    )
    |> FastestMCP.add_resource_template(
      "notes://{id}",
      fn %{"id" => id}, _ctx ->
        Notes.get(id) || raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
      end,
      name: "note",
      description: "A note, by its id."
    )
    |> FastestMCP.add_prompt(
      "summarize_notes",
      fn %{"topic" => topic}, _ctx ->
        notes = Enum.map_join(Notes.search(topic), "\n", &"- #{&1.title}: #{&1.body}")
        "Summarize my notes about #{topic}:\n\n#{notes}"
      end,
      description: "Ask the model to summarize your notes about a topic.",
      arguments: [%{name: "topic", description: "What the notes are about", required: true}]
    )
  end
end
