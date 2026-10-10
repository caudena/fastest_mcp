defmodule FastestMCP.Middleware.Timing do
  @moduledoc false

  require Logger

  @behaviour FastestMCP.Middleware

  alias FastestMCP.Component
  alias FastestMCP.Operation

  defstruct [:log_fn, label: nil, log_level: :info]

  def new(opts \\ []) do
    %__MODULE__{
      log_fn: Keyword.get(opts, :log_fn, &Logger.log/2),
      label: Keyword.get(opts, :label),
      log_level: Keyword.get(opts, :log_level, :info)
    }
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    started_at = System.monotonic_time()
    label = label(middleware.label, operation)
    result = next.(operation)

    outcome =
      case result do
        {:ok, _operation} ->
          "completed in #{elapsed_ms(started_at)}ms"

        {:error, error} ->
          "failed after #{elapsed_ms(started_at)}ms: #{Exception.message(error)}"
      end

    middleware.log_fn.(middleware.log_level, "#{label} #{outcome}")
    result
  end

  # Milliseconds since the native monotonic `started_at`, rounded to 0.01.
  def elapsed_ms(started_at) do
    (System.monotonic_time() - started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(2)
  end

  defp label(nil, operation), do: "Request #{operation.method}"
  defp label(label, operation) when is_function(label, 1), do: label.(operation)

  defp label(:detailed, %Operation{method: method, target: target}) do
    cond do
      kind = Component.call_kind(method) ->
        "#{String.capitalize(Component.label(kind))} '#{target}'"

      kind = Component.list_kind(method) ->
        "List #{kind |> Component.collection() |> Atom.to_string() |> String.replace("_", " ")}"

      method in ["initialize", "ping"] ->
        String.capitalize(method)

      true ->
        "Request #{method}"
    end
  end
end
