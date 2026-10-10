# lib/my_app/notes.ex
defmodule MyApp.Notes do
  # Keeps notes in memory, so the tutorial needs no database. In a real
  # application this is one of your contexts, and it uses your Repo.
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def create(title, body) do
    Agent.get_and_update(__MODULE__, fn notes ->
      note = %{id: Integer.to_string(length(notes) + 1), title: title, body: body}
      {note, notes ++ [note]}
    end)
  end

  def get(id), do: Agent.get(__MODULE__, fn notes -> Enum.find(notes, &(&1.id == id)) end)

  def search(query) do
    query = String.downcase(query)

    Agent.get(__MODULE__, fn notes ->
      Enum.filter(notes, &String.contains?(String.downcase(&1.title <> " " <> &1.body), query))
    end)
  end
end
