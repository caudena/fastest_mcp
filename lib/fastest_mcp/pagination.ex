defmodule FastestMCP.Pagination do
  @moduledoc """
  Cursor pagination helpers shared by list operations.

  Transport pagination uses a server-selected page size and a signed keyset
  cursor. The cursor is bound to the list method and caller visibility/filter
  scope so it cannot be reused against another method, principal, or policy.

  The older offset helpers remain available for Elixir-native callers. They are
  deliberately not used by MCP transports.
  """

  alias FastestMCP.Error

  @default_page_size 100
  @max_cursor_bytes 4_096
  @cursor_version 1

  @doc "Returns the default server-owned MCP page size."
  def default_page_size, do: @default_page_size

  @doc "Encodes an offset for Elixir-native pagination."
  def encode_cursor(offset) when is_integer(offset) and offset >= 0 do
    %{"offset" => offset}
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "Decodes an Elixir-native offset cursor."
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

  @doc "Paginates an Elixir-native list only when `:page_size` is supplied."
  def maybe_paginate(items, opts) when is_list(items) do
    case Keyword.get(opts, :page_size) do
      nil -> items
      page_size -> paginate(items, Keyword.get(opts, :cursor), page_size)
    end
  end

  @doc "Applies offset pagination for Elixir-native callers."
  def paginate(items, cursor, page_size) when is_list(items) do
    validate_page_size!(page_size)
    offset = decode_cursor!(cursor)
    {page, remaining} = items |> Enum.drop(offset) |> Enum.split(page_size)

    %{
      items: page,
      next_cursor: if(remaining == [], do: nil, else: encode_cursor(offset + length(page)))
    }
  end

  @doc """
  Applies signed keyset pagination for an MCP list response.

  Required options are `:secret` and `:scope`. `:fingerprint` binds the cursor
  to caller-visible state. `:key` may provide a stable key function; otherwise
  component metadata fields are used.
  """
  def wire_page(items, opts) when is_list(items) and is_list(opts) do
    secret = validate_secret!(Keyword.fetch!(opts, :secret))
    scope = normalize_binding(Keyword.fetch!(opts, :scope))
    fingerprint = normalize_binding(Keyword.get(opts, :fingerprint, "public"))
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    key_fun = Keyword.get(opts, :key, &default_key/1)
    validate_page_size!(page_size)

    after_key =
      decode_wire_cursor!(Keyword.get(opts, :cursor), secret, scope, fingerprint)

    remaining =
      items
      |> Enum.map(&{normalize_key(key_fun.(&1)), &1})
      |> Enum.sort_by(&elem(&1, 0))
      |> drop_through(after_key)

    {selected, overflow} = Enum.split(remaining, page_size)
    page = Enum.map(selected, &elem(&1, 1))

    next_cursor =
      case {selected, overflow} do
        {[], _} ->
          nil

        {_selected, []} ->
          nil

        {_selected, _overflow} ->
          last_key = selected |> List.last() |> elem(0)
          encode_wire_cursor(last_key, secret, scope, fingerprint)
      end

    %{items: page, next_cursor: next_cursor}
  end

  @doc false
  def wire_page(opts, source) when is_list(opts) and is_function(source, 2) do
    secret = validate_secret!(Keyword.fetch!(opts, :secret))
    scope = normalize_binding(Keyword.fetch!(opts, :scope))
    fingerprint = normalize_binding(Keyword.get(opts, :fingerprint, "public"))
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    key_fun = Keyword.get(opts, :key, &default_key/1)
    validate_page_size!(page_size)

    after_key =
      decode_wire_cursor!(Keyword.get(opts, :cursor), secret, scope, fingerprint)

    candidates = source.(after_key, page_size + 1)

    unless is_list(candidates) do
      raise Error,
        code: :internal_error,
        message: "pagination source must return a list"
    end

    selected =
      candidates
      |> keyset_items(after_key, page_size + 1, key_fun)

    {page, overflow} = Enum.split(selected, page_size)

    next_cursor =
      case {page, overflow} do
        {[], _overflow} ->
          nil

        {_page, []} ->
          nil

        {_page, _overflow} ->
          last_key = page |> List.last() |> key_fun.() |> normalize_key()
          encode_wire_cursor(last_key, secret, scope, fingerprint)
      end

    %{items: page, next_cursor: next_cursor}
  end

  @doc "Returns a bounded, stable keyset page for a provider source."
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

  @doc false
  def normalize_source_key(nil), do: nil
  def normalize_source_key(key), do: normalize_key(key)

  @doc false
  def default_key(item) when is_map(item) do
    identifier =
      fetch(item, :name) || fetch(item, :uri) || fetch(item, :uri_template) ||
        fetch(item, :uriTemplate) || fetch(item, :key)

    if is_nil(identifier) do
      [JSON.encode!(stringify_keys(item))]
    else
      [to_string(identifier), to_string(fetch(item, :version) || "")]
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

  defp decode_wire_cursor!(nil, _secret, _scope, _fingerprint), do: nil

  defp decode_wire_cursor!(cursor, secret, scope, fingerprint)
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
      normalize_key(after_key)
    else
      _other -> invalid_cursor!()
    end
  end

  defp decode_wire_cursor!(_cursor, _secret, _scope, _fingerprint), do: invalid_cursor!()

  defp drop_through(items, nil), do: items

  defp drop_through(items, after_key) do
    Enum.drop_while(items, fn {key, _item} -> key <= after_key end)
  end

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

  defp validate_page_size!(page_size) when is_integer(page_size) and page_size > 0,
    do: :ok

  defp validate_page_size!(_page_size) do
    raise Error, code: :bad_request, message: "page_size must be a positive integer"
  end

  defp decode_cursor!(nil), do: 0

  defp decode_cursor!(cursor) do
    case decode_cursor(cursor) do
      {:ok, offset} -> offset
      {:error, :invalid_cursor} -> invalid_cursor!()
    end
  end

  defp invalid_cursor! do
    raise Error, code: :bad_request, message: "invalid cursor"
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp fetch(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
