defmodule FastestMCP.Client.Paginator do
  @moduledoc false

  alias FastestMCP.Error

  @default_max_pages 256
  @default_max_items 100_000

  @type page :: %{
          required(:items) => list(),
          required(:next_cursor) => String.t() | nil,
          optional(:ttl_ms) => non_neg_integer(),
          optional(:cache_scope) => String.t()
        }

  @spec fetch_all((String.t() | nil -> {:ok, page()} | {:error, term()}), keyword()) ::
          {:ok, list()} | {:error, term()}
  def fetch_all(fetch_page, opts \\ []) when is_function(fetch_page, 1) do
    case fetch_all_with_meta(fetch_page, opts) do
      {:ok, %{items: items}} -> {:ok, items}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec fetch_all_with_meta(
          (String.t() | nil -> {:ok, page()} | {:error, term()}),
          keyword()
        ) ::
          {:ok,
           %{
             items: list(),
             ttl_ms: non_neg_integer() | nil,
             cache_scope: String.t()
           }}
          | {:error, term()}
  def fetch_all_with_meta(fetch_page, opts \\ []) when is_function(fetch_page, 1) do
    with {:ok, max_pages} <- positive_limit(opts, :max_pages, @default_max_pages),
         {:ok, max_items} <- positive_limit(opts, :max_items, @default_max_items) do
      walk(fetch_page, nil, MapSet.new(), [], :unset, nil, 0, 0, max_pages, max_items)
    end
  end

  defp walk(
         _fetch_page,
         _cursor,
         _seen,
         _pages,
         _ttl_ms,
         _cache_scope,
         page_count,
         _item_count,
         max_pages,
         _max_items
       )
       when page_count >= max_pages do
    {:error,
     %Error{
       code: :overloaded,
       message: "pagination exceeded the client page limit",
       details: %{max_pages: max_pages}
     }}
  end

  defp walk(
         fetch_page,
         cursor,
         seen,
         pages,
         ttl_ms,
         cache_scope,
         page_count,
         item_count,
         max_pages,
         max_items
       ) do
    case fetch_page.(cursor) do
      {:ok, %{items: items} = page} when is_list(items) ->
        next_cursor = Map.get(page, :next_cursor)
        next_item_count = item_count + length(items)

        cond do
          next_item_count > max_items ->
            {:error,
             %Error{
               code: :overloaded,
               message: "pagination exceeded the client item limit",
               details: %{max_items: max_items}
             }}

          not (is_nil(next_cursor) or is_binary(next_cursor)) ->
            {:error, invalid_page("next_cursor must be a binary or nil")}

          is_nil(next_cursor) ->
            {:ok,
             %{
               items: flatten_pages([items | pages]),
               ttl_ms: ttl_ms |> page_ttl(page) |> final_ttl(),
               cache_scope: page_cache_scope(cache_scope, page)
             }}

          MapSet.member?(seen, next_cursor) ->
            {:error,
             %Error{
               code: :invalid_request,
               message: "pagination returned a repeated cursor",
               details: %{cursor: next_cursor}
             }}

          true ->
            walk(
              fetch_page,
              next_cursor,
              MapSet.put(seen, next_cursor),
              [items | pages],
              page_ttl(ttl_ms, page),
              page_cache_scope(cache_scope, page),
              page_count + 1,
              next_item_count,
              max_pages,
              max_items
            )
        end

      {:ok, _invalid_page} ->
        {:error, invalid_page("page must contain an items list")}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, invalid_page("page callback returned #{inspect(other)}")}
    end
  end

  defp flatten_pages(pages), do: pages |> Enum.reverse() |> Enum.concat()

  defp page_ttl(:unset, page), do: first_page_ttl(page)
  defp page_ttl(:absent, page), do: merge_absent_ttl(page)

  defp page_ttl({:explicit, current}, %{ttl_ms: ttl_ms})
       when is_integer(ttl_ms) and ttl_ms >= 0,
       do: {:explicit, min(current, ttl_ms)}

  defp page_ttl({:explicit, _current}, %{ttl_ms: _invalid}), do: :uncacheable
  defp page_ttl({:explicit, _current}, _page), do: :uncacheable
  defp page_ttl(:uncacheable, _page), do: :uncacheable

  defp first_page_ttl(%{ttl_ms: ttl_ms}) when is_integer(ttl_ms) and ttl_ms >= 0,
    do: {:explicit, ttl_ms}

  defp first_page_ttl(%{ttl_ms: _invalid}), do: :uncacheable
  defp first_page_ttl(_page), do: :absent

  defp merge_absent_ttl(%{ttl_ms: _ttl_ms}), do: :uncacheable
  defp merge_absent_ttl(_page), do: :absent

  # A wholly unhinted legacy result remains non-expiring. Mixed hinted and
  # unhinted pages, or malformed hints, are conservatively immediately stale.
  defp final_ttl(:absent), do: nil
  defp final_ttl({:explicit, ttl_ms}), do: ttl_ms
  defp final_ttl(:uncacheable), do: 0

  defp page_cache_scope(nil, %{cache_scope: "public"}), do: "public"
  defp page_cache_scope("public", %{cache_scope: "public"}), do: "public"
  defp page_cache_scope(_current, _page), do: "private"

  defp positive_limit(opts, key, default) when is_list(opts) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, invalid_limit(key, value)}
    end
  end

  defp invalid_limit(key, value) do
    %Error{
      code: :invalid_params,
      message: "#{key} must be a positive integer",
      details: %{option: key, value: inspect(value)}
    }
  end

  defp invalid_page(reason) do
    %Error{
      code: :invalid_request,
      message: "invalid paginated response",
      details: %{reason: reason}
    }
  end
end
