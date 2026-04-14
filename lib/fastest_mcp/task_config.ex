defmodule FastestMCP.TaskConfig do
  @moduledoc """
  Local background-task execution settings for tools, prompts, and resources.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  defstruct mode: :forbidden, poll_interval_ms: 5_000

  @type mode :: :forbidden | :optional | :required

  @type t :: %__MODULE__{
          mode: mode(),
          poll_interval_ms: pos_integer()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(value \\ false)
  def new(%__MODULE__{} = config), do: validate!(config)
  def new(nil), do: %__MODULE__{}
  def new(false), do: %__MODULE__{mode: :forbidden}
  def new(true), do: %__MODULE__{mode: :optional}

  def new(opts) when is_list(opts) do
    %__MODULE__{
      mode: normalize_mode(Keyword.get(opts, :mode, :optional)),
      poll_interval_ms: normalize_poll_interval(Keyword.get(opts, :poll_interval_ms, 5_000))
    }
    |> validate!()
  end

  @doc "Returns whether task execution is supported."
  def supports_tasks?(%__MODULE__{mode: :forbidden}), do: false
  def supports_tasks?(%__MODULE__{}), do: true

  @doc "Returns the metadata map carried by this task configuration."
  def metadata(%__MODULE__{} = config) do
    %{
      mode: Atom.to_string(config.mode),
      poll_interval_ms: config.poll_interval_ms
    }
  end

  defp validate!(%__MODULE__{mode: mode, poll_interval_ms: poll_interval_ms} = config)
       when mode in [:forbidden, :optional, :required] and is_integer(poll_interval_ms) and
              poll_interval_ms > 0 do
    config
  end

  defp validate!(config) do
    raise ArgumentError, "invalid task config #{inspect(config)}"
  end

  defp normalize_mode(mode) when mode in [:forbidden, :optional, :required], do: mode
  defp normalize_mode("forbidden"), do: :forbidden
  defp normalize_mode("optional"), do: :optional
  defp normalize_mode("required"), do: :required

  defp normalize_mode(mode) do
    raise ArgumentError,
          "task mode must be :forbidden, :optional, or :required, got #{inspect(mode)}"
  end

  defp normalize_poll_interval(value) when is_integer(value) and value > 0, do: value

  defp normalize_poll_interval(value) do
    raise ArgumentError, "task poll_interval_ms must be a positive integer, got #{inspect(value)}"
  end
end
