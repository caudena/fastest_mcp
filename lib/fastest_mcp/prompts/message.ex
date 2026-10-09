defmodule FastestMCP.Prompts.Message do
  @moduledoc """
  Prompt message helper with content normalization.

  This helper exists for the cases where a prompt wants explicit control over
  roles and content blocks without forcing every handler to build raw MCP maps
  by hand.

  Accepted content forms:

    * strings - emitted as text content
    * MCP-style content maps - passed through
    * maps, lists, tuples, structs, and other values - JSON encoded as text

  ## Examples

  ```elixir
  FastestMCP.Prompts.Message.new("Summarize the diff")
  FastestMCP.Prompts.Message.new("Done.", role: :assistant)
  FastestMCP.Prompts.Message.new(%{
    type: "resource",
    resource: %{uri: "file:///tmp/out.txt", mimeType: "text/plain", text: "Done"}
  })
  ```
  """

  import FastestMCP.Util, only: [maybe_put: 3, optional_map!: 2, string_keys: 1]

  alias FastestMCP.JSONValue

  defstruct role: "user", content: nil, meta: nil

  @type role :: :user | :assistant | String.t()

  @type t :: %__MODULE__{
          role: String.t(),
          content: any(),
          meta: map() | nil
        }

  @doc "Builds a normalized prompt message."
  def new(content, opts \\ []) do
    %__MODULE__{
      role: normalize_role(Keyword.get(opts, :role, "user")),
      content: normalize_content(content),
      meta: optional_map!(Keyword.get(opts, :meta), "prompt message meta")
    }
  end

  @doc "Normalizes a message-like value into `%FastestMCP.Prompts.Message{}`."
  def from(%__MODULE__{} = message), do: message

  # Application code gives messages with atom or string keys.
  def from(%{} = message) do
    message = string_keys(message)

    new(Map.get(message, "content", ""),
      role: Map.get(message, "role", "user"),
      meta: Map.get(message, "_meta", message["meta"])
    )
  end

  def from(message) when is_binary(message), do: new(message)

  def from(other) do
    raise ArgumentError,
          "prompt messages must be strings, maps, or FastestMCP.Prompts.Message values, got #{inspect(other)}"
  end

  @doc "Converts the helper struct into the normalized prompt-message map used by the runtime."
  def to_map(%__MODULE__{} = message) do
    %{}
    |> Map.put(:role, message.role)
    |> Map.put(:content, message.content)
    |> maybe_put(:meta, message.meta)
  end

  defp normalize_role(role) when role in [:user, :assistant], do: Atom.to_string(role)
  defp normalize_role(role) when role in ["user", "assistant"], do: role

  defp normalize_role(other) do
    raise ArgumentError, "prompt message role must be :user or :assistant, got #{inspect(other)}"
  end

  # A content map keeps the application's keys until it is serialized.
  defp normalize_content(%{type: type} = content) when is_binary(type), do: content
  defp normalize_content(%{"type" => type} = content) when is_binary(type), do: content
  defp normalize_content(content) when is_binary(content), do: %{type: "text", text: content}

  defp normalize_content(content) do
    %{type: "text", text: JSONValue.encode!(content)}
  end
end
