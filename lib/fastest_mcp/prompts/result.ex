defmodule FastestMCP.Prompts.Result do
  @moduledoc """
  Canonical prompt result helper.

  `FastestMCP.Prompts.Result` gives prompt handlers one explicit return type
  when they need multiple messages, custom roles, or result-level metadata.

  Accepted message inputs:

    * a string - wrapped as one user message
    * a list of `FastestMCP.Prompts.Message`

  Bare single-message structs are rejected on purpose. Use a list to make the
  cardinality explicit.

  ## Examples

  ```elixir
  FastestMCP.Prompts.Result.new("Hello")

  FastestMCP.Prompts.Result.new([
    FastestMCP.Prompts.Message.new("Review this diff"),
    FastestMCP.Prompts.Message.new("I can do that.", role: :assistant)
  ], description: "Code review prompt")
  ```
  """

  import FastestMCP.Util, only: [maybe_put: 3, optional_map!: 2, string_keys: 1]

  alias FastestMCP.Prompts.Message

  defstruct messages: [], description: nil, meta: nil, extra: %{}

  @type t :: %__MODULE__{
          messages: [Message.t()],
          description: String.t() | nil,
          meta: map() | nil,
          extra: map()
        }

  @doc "Builds a normalized prompt result."
  def new(messages, opts \\ []) do
    %__MODULE__{
      messages: normalize_messages(messages),
      description: Keyword.get(opts, :description),
      meta: optional_map!(Keyword.get(opts, :meta), "prompt result meta")
    }
  end

  @doc "Normalizes prompt-result input into `%FastestMCP.Prompts.Result{}`."
  def from(%__MODULE__{} = result), do: result

  # Application code gives envelopes with atom or string keys.
  def from(%{} = value) do
    %{"messages" => messages} = value = string_keys(value)

    new(Enum.map(messages, &Message.from/1),
      description: value["description"],
      meta: Map.get(value, "_meta", value["meta"])
    )
  end

  def from(value) when is_binary(value), do: new(value)
  def from(value) when is_list(value), do: new(value)

  @doc "Builds an explicit envelope from a validated MCP prompt result."
  def from_raw(%{} = raw) do
    %__MODULE__{
      messages: Map.fetch!(raw, "messages"),
      description: Map.get(raw, "description"),
      meta: Map.get(raw, "_meta"),
      extra: Map.drop(raw, ["messages", "description"])
    }
  end

  @doc "Converts the helper struct into the normalized prompt-result map used by the runtime."
  def to_map(%__MODULE__{} = result) do
    %{}
    |> Map.put(:messages, Enum.map(result.messages, &Message.to_map/1))
    |> maybe_put(:description, result.description)
    |> maybe_put(:meta, result.meta)
  end

  defp normalize_messages(messages) when is_binary(messages), do: [Message.new(messages)]

  defp normalize_messages(messages) when is_list(messages) do
    Enum.with_index(messages)
    |> Enum.map(fn {item, index} ->
      if match?(%Message{}, item) do
        Message.from(item)
      else
        raise ArgumentError,
              "messages[#{index}] must be FastestMCP.Prompts.Message, got #{inspect(item)}"
      end
    end)
  end

  defp normalize_messages(%Message{} = _message) do
    raise ArgumentError,
          "messages must be a string or list[FastestMCP.Prompts.Message], got a bare message"
  end

  defp normalize_messages(other) do
    raise ArgumentError,
          "messages must be a string or list[FastestMCP.Prompts.Message], got #{inspect(other)}"
  end
end
