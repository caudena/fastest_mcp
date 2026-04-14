defmodule FastestMCP.TaskMeta do
  @moduledoc """
  Explicit background-task request metadata for direct in-process operations.

  Passing `task_meta:` to `FastestMCP.call_tool/4`, `FastestMCP.read_resource/3`,
  or `FastestMCP.render_prompt/4` requests task execution while keeping the
  direct API synchronous-by-default.
  """

  defstruct ttl: nil

  @type t :: %__MODULE__{
          ttl: pos_integer() | nil
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ [])
  def new(%__MODULE__{} = meta), do: validate!(meta)
  def new(nil), do: %__MODULE__{}

  def new(opts) when is_list(opts) do
    %__MODULE__{
      ttl: normalize_ttl(Keyword.get(opts, :ttl))
    }
    |> validate!()
  end

  def new(%{} = opts) do
    opts
    |> Enum.into([])
    |> new()
  end

  @doc "Normalizes input into the runtime shape expected by this module."
  def normalize(nil), do: nil
  def normalize(%__MODULE__{} = meta), do: new(meta)
  def normalize(opts), do: new(opts)

  defp validate!(%__MODULE__{ttl: ttl} = meta) when is_nil(ttl) or (is_integer(ttl) and ttl > 0),
    do: meta

  defp validate!(meta) do
    raise ArgumentError, "invalid task meta #{inspect(meta)}"
  end

  defp normalize_ttl(nil), do: nil
  defp normalize_ttl(ttl) when is_integer(ttl) and ttl > 0, do: ttl

  defp normalize_ttl(ttl) do
    raise ArgumentError, "task ttl must be a positive integer, got #{inspect(ttl)}"
  end
end
