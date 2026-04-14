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

  alias FastestMCP.Prompts.Message

  defstruct messages: [], description: nil, meta: nil

  @type t :: %__MODULE__{
          messages: [Message.t()],
          description: String.t() | nil,
          meta: map() | nil
        }

  @doc "Builds a normalized prompt result."
  def new(messages, opts \\ []) do
    %__MODULE__{
      messages: normalize_messages(messages),
      description: Keyword.get(opts, :description),
      meta: normalize_optional_map(Keyword.get(opts, :meta))
    }
  end

  @doc "Normalizes prompt-result input into `%FastestMCP.Prompts.Result{}`."
  def from(%__MODULE__{} = result), do: result

  def from(%{} = value) when is_map_key(value, :messages) or is_map_key(value, "messages") do
    new(
      Map.get(value, :messages, Map.get(value, "messages")),
      description: Map.get(value, :description, Map.get(value, "description")),
      meta: Map.get(value, :meta, Map.get(value, "meta"))
    )
  end

  def from(value) when is_binary(value), do: new(value)
  def from(value) when is_list(value), do: new(value)

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

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(map) when is_map(map), do: Map.new(map)

  defp normalize_optional_map(other) do
    raise ArgumentError, "prompt result meta must be a map, got #{inspect(other)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
