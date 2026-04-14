defmodule FastestMCP.Pagination do
  @moduledoc """
  Cursor pagination helpers shared by list operations.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Error

  @doc "Encodes an offset into an opaque cursor."
  def encode_cursor(offset) when is_integer(offset) and offset >= 0 do
    %{"offset" => offset}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "Decodes an opaque cursor back into an offset."
  def decode_cursor(cursor) when is_binary(cursor) and cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"offset" => offset}} <- Jason.decode(decoded),
         true <- is_integer(offset) and offset >= 0 do
      {:ok, offset}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_cursor), do: {:error, :invalid_cursor}

  @doc "Paginates items when pagination options are present."
  def maybe_paginate(items, opts) when is_list(items) do
    case Keyword.get(opts, :page_size) do
      nil ->
        items

      page_size ->
        paginate(items, Keyword.get(opts, :cursor), page_size)
    end
  end

  @doc "Applies cursor pagination to the given items."
  def paginate(items, cursor, page_size) when is_list(items) do
    validate_page_size!(page_size)
    offset = decode_cursor!(cursor)
    paginated(items, offset, page_size)
  end

  defp paginated(items, offset, page_size) do
    page = Enum.slice(items, offset, page_size)
    next_offset = offset + page_size

    %{
      items: page,
      next_cursor: if(next_offset < length(items), do: encode_cursor(next_offset), else: nil)
    }
  end

  defp validate_page_size!(page_size) when is_integer(page_size) and page_size > 0, do: :ok

  defp validate_page_size!(_page_size) do
    raise Error, code: :bad_request, message: "page_size must be a positive integer"
  end

  defp decode_cursor!(nil), do: 0

  defp decode_cursor!(cursor) do
    case decode_cursor(cursor) do
      {:ok, offset} -> offset
      {:error, :invalid_cursor} -> raise Error, code: :bad_request, message: "invalid cursor"
    end
  end
end
