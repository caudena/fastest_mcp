defmodule FastestMCP.Protocol.Progress do
  @moduledoc false

  @type supplied_total :: :absent | {:provided, number() | term()}

  @doc false
  @spec total(map()) :: supplied_total()
  def total(params) when is_map(params) do
    cond do
      Map.has_key?(params, "total") -> {:provided, Map.get(params, "total")}
      Map.has_key?(params, :total) -> {:provided, Map.get(params, :total)}
      true -> :absent
    end
  end

  def total(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :total),
      do: {:provided, Keyword.get(opts, :total)},
      else: :absent
  end

  @doc false
  @spec validate_update(term(), term(), supplied_total(), term()) ::
          {:ok, number() | nil} | {:error, atom()}
  def validate_update(progress, previous, total, previous_total) do
    with :ok <- validate_progress(progress, previous),
         {:ok, total} <- validate_total(total, previous_total) do
      {:ok, total}
    end
  end

  defp validate_progress(progress, _previous) when not is_number(progress),
    do: {:error, :invalid_progress}

  defp validate_progress(progress, previous)
       when is_number(previous) and progress <= previous,
       do: {:error, :non_increasing_progress}

  defp validate_progress(_progress, _previous), do: :ok

  defp validate_total(:absent, previous_total), do: {:ok, previous_total}

  defp validate_total({:provided, total}, _previous_total) when not is_number(total),
    do: {:error, :invalid_total}

  defp validate_total({:provided, total}, _previous_total), do: {:ok, total}
end
