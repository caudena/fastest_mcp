defmodule FastestMCP.Pagination do
  @moduledoc false
  # MCP list responses use a server-chosen page size and a signed keyset cursor
  # bound to the method and the caller's visibility/filter scope, so a cursor
  # cannot be replayed against another method, principal, or policy. Offset
  # cursors are for Elixir-native callers only.

  import FastestMCP.Util, only: [secure_equal?: 2, stringify_keys: 1]

  alias FastestMCP.Error

  @default_page_size 100
  @max_cursor_bytes 4_096
  @cursor_version 1

  def encode_cursor(offset) when is_integer(offset) and offset >= 0 do
    %{"offset" => offset}
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  def decode_cursor(cursor) when is_binary(cursor) and cursor != "" do
    with true <- byte_size(cursor) <= @max_cursor_bytes,
         {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"offset" => offset}} <- JSON.decode(decoded),
         true <- is_integer(offset) and offset >= 0 do
      {:ok, offset}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_cursor), do: {:error, :invalid_cursor}

  # `{:ok, items}` without `:page_size`, else the result of `paginate/3`.
  def maybe_paginate(items, opts) when is_list(items) do
    case Keyword.get(opts, :page_size) do
      nil -> {:ok, items}
      page_size -> paginate(items, Keyword.get(opts, :cursor), page_size)
    end
  end

  # `{:ok, %{items:, next_cursor:}}`, or a `:bad_request` error for an invalid
  # cursor or page size.
  def paginate(items, cursor, page_size) when is_list(items) do
    with :ok <- validate_page_size(page_size),
         {:ok, offset} <- offset(cursor) do
      {page, remaining} = items |> Enum.drop(offset) |> Enum.split(page_size)
      next_cursor = if remaining != [], do: encode_cursor(offset + length(page))
      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  # Requires `:secret` and `:scope`; `:fingerprint` binds the cursor to
  # caller-visible state, and `:key` replaces the component-metadata key.
  def wire_page(items, opts) when is_list(items) and is_list(opts),
    do: wire_page(opts, fn _after_key, _limit -> {:ok, items} end)

  # The page of `source.(after_key, limit)`, which returns `{:ok, items}` with
  # at least the `limit` items after `after_key` it has, or an error.
  def wire_page(opts, source) when is_list(opts) and is_function(source, 2) do
    secret = validate_secret!(Keyword.fetch!(opts, :secret))
    scope = normalize_binding(Keyword.fetch!(opts, :scope))
    fingerprint = normalize_binding(Keyword.get(opts, :fingerprint, "public"))
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    key_fun = Keyword.get(opts, :key, &default_key/1)
    cursor = Keyword.get(opts, :cursor)

    with :ok <- validate_page_size(page_size),
         {:ok, after_key} <- decode_wire_cursor(cursor, secret, scope, fingerprint),
         {:ok, candidates} <- source.(after_key, page_size + 1) do
      {page, overflow} =
        candidates |> keyset_items(after_key, page_size + 1, key_fun) |> Enum.split(page_size)

      next_cursor =
        if page != [] and overflow != [] do
          page
          |> List.last()
          |> key_fun.()
          |> normalize_key()
          |> encode_wire_cursor(secret, scope, fingerprint)
        end

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  def source_page(items, after_key, limit, opts \\ [])
      when is_integer(limit) and limit > 0 and is_list(opts) do
    key_fun = Keyword.get(opts, :key, &default_key/1)
    selected = keyset_items(items, after_key, limit + 1, key_fun)
    {page, overflow} = Enum.split(selected, limit)

    next_after =
      case {page, overflow} do
        {[], _overflow} -> nil
        {_page, []} -> nil
        {_page, _overflow} -> page |> List.last() |> key_fun.() |> normalize_key()
      end

    %{items: page, next_after: next_after}
  end

  def normalize_source_key(nil), do: nil
  def normalize_source_key(key), do: normalize_key(key)

  # Items are components or their `Component.metadata/1` maps.
  def default_key(item) when is_map(item) do
    case Map.get(item, :name) || Map.get(item, :uri) || Map.get(item, :uri_template) ||
           Map.get(item, :key) do
      nil -> [JSON.encode!(stringify_keys(item))]
      identifier -> [to_string(identifier), to_string(Map.get(item, :version) || "")]
    end
  end

  def default_key(item), do: [inspect(item)]

  defp keyset_items(items, after_key, limit, key_fun) do
    after_key = if is_nil(after_key), do: nil, else: normalize_key(after_key)

    items
    |> Enum.reduce([], fn item, selected ->
      key = item |> key_fun.() |> normalize_key()

      if is_nil(after_key) or key > after_key do
        bounded_insert(selected, {key, item}, limit)
      else
        selected
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp bounded_insert(selected, entry, limit) do
    selected = insert_sorted(selected, entry)

    if length(selected) > limit do
      List.delete_at(selected, -1)
    else
      selected
    end
  end

  defp insert_sorted([], entry), do: [entry]

  defp insert_sorted([{key, _item} = current | rest], {new_key, _new_item} = entry)
       when new_key < key do
    [entry, current | rest]
  end

  defp insert_sorted([current | rest], entry), do: [current | insert_sorted(rest, entry)]

  defp encode_wire_cursor(after_key, secret, scope, fingerprint) do
    body =
      JSON.encode!(%{
        "v" => @cursor_version,
        "scope" => scope,
        "fingerprint" => fingerprint,
        "after" => after_key
      })

    signature = :crypto.mac(:hmac, :sha256, secret, body)

    Base.url_encode64(body, padding: false) <>
      "." <> Base.url_encode64(signature, padding: false)
  end

  defp decode_wire_cursor(nil, _secret, _scope, _fingerprint), do: {:ok, nil}

  defp decode_wire_cursor(cursor, secret, scope, fingerprint)
       when is_binary(cursor) and cursor != "" and byte_size(cursor) <= @max_cursor_bytes do
    with [encoded_body, encoded_signature] <- String.split(cursor, ".", parts: 2),
         {:ok, body} <- Base.url_decode64(encoded_body, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, secret, body),
         true <- secure_equal?(signature, expected),
         {:ok,
          %{
            "v" => @cursor_version,
            "scope" => ^scope,
            "fingerprint" => ^fingerprint,
            "after" => after_key
          }} <- JSON.decode(body) do
      {:ok, normalize_key(after_key)}
    else
      _other -> invalid_cursor()
    end
  end

  defp decode_wire_cursor(_cursor, _secret, _scope, _fingerprint), do: invalid_cursor()

  defp normalize_key(key) when is_list(key), do: Enum.map(key, &normalize_key_part/1)
  defp normalize_key(key), do: [normalize_key_part(key)]

  defp normalize_key_part(value) when is_binary(value), do: value
  defp normalize_key_part(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_key_part(value), do: inspect(value)

  defp normalize_binding(value) when is_binary(value), do: value
  defp normalize_binding(value), do: value |> stringify_keys() |> JSON.encode!()

  defp validate_secret!(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret

  defp validate_secret!(_secret) do
    raise ArgumentError, "pagination cursor secret must contain at least 32 bytes"
  end

  defp validate_page_size(page_size) when is_integer(page_size) and page_size > 0, do: :ok

  defp validate_page_size(_page_size),
    do: {:error, %Error{code: :bad_request, message: "page_size must be a positive integer"}}

  defp offset(nil), do: {:ok, 0}

  defp offset(cursor) do
    with {:error, :invalid_cursor} <- decode_cursor(cursor), do: invalid_cursor()
  end

  defp invalid_cursor, do: {:error, %Error{code: :bad_request, message: "invalid cursor"}}
end
