defmodule FastestMCP.ClientPaginatorTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Client.Paginator
  alias FastestMCP.Error

  test "preserves empty cursors, item order, and list-valued items" do
    fetch_page = fn
      nil ->
        {:ok,
         %{
           items: [[1, 2], :first],
           next_cursor: "",
           ttl_ms: 500,
           cache_scope: "public"
         }}

      "" ->
        {:ok,
         %{
           items: [[:nested], :last],
           next_cursor: nil,
           ttl_ms: 200,
           cache_scope: "private"
         }}
    end

    assert {:ok,
            %{
              items: [[1, 2], :first, [:nested], :last],
              ttl_ms: 200,
              cache_scope: "private"
            }} = Paginator.fetch_all_with_meta(fetch_page)
  end

  test "keeps absent TTL distinct from zero and conservatively combines page hints" do
    assert {:ok, %{ttl_ms: nil}} =
             Paginator.fetch_all_with_meta(fn nil ->
               {:ok, %{items: [:legacy], next_cursor: nil}}
             end)

    assert {:ok, %{ttl_ms: 0}} =
             Paginator.fetch_all_with_meta(fn nil ->
               {:ok, %{items: [:modern], next_cursor: nil, ttl_ms: 0}}
             end)

    assert {:ok, %{ttl_ms: 200}} =
             Paginator.fetch_all_with_meta(fn
               nil -> {:ok, %{items: [:first], next_cursor: "next", ttl_ms: 500}}
               "next" -> {:ok, %{items: [:second], next_cursor: nil, ttl_ms: 200}}
             end)

    assert {:ok, %{ttl_ms: 0}} =
             Paginator.fetch_all_with_meta(fn
               nil -> {:ok, %{items: [:hinted], next_cursor: "next", ttl_ms: 500}}
               "next" -> {:ok, %{items: [:unhinted], next_cursor: nil}}
             end)

    assert {:ok, %{ttl_ms: 0}} =
             Paginator.fetch_all_with_meta(fn nil ->
               {:ok, %{items: [:malformed], next_cursor: nil, ttl_ms: "500"}}
             end)
  end

  test "rejects repeated cursors without partial success" do
    fetch_page = fn
      nil -> {:ok, %{items: [1], next_cursor: "again"}}
      "again" -> {:ok, %{items: [2], next_cursor: "again"}}
    end

    assert {:error, %Error{code: :invalid_request, details: %{cursor: "again"}}} =
             Paginator.fetch_all(fetch_page)
  end

  test "enforces page and item bounds" do
    pages = fn
      nil -> {:ok, %{items: [:one], next_cursor: "second"}}
      "second" -> {:ok, %{items: [:two], next_cursor: nil}}
    end

    assert {:error, %Error{code: :overloaded, details: %{max_pages: 1}}} =
             Paginator.fetch_all(pages, max_pages: 1)

    assert {:error, %Error{code: :overloaded, details: %{max_items: 1}}} =
             Paginator.fetch_all(pages, max_items: 1)
  end

  test "propagates callback failures unchanged" do
    error = %Error{code: :timeout, message: "upstream timed out"}

    assert {:error, ^error} = Paginator.fetch_all(fn nil -> {:error, error} end)
  end
end
