defmodule FastestMCP.AuthCIMDTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.CIMD
  alias FastestMCP.Auth.CIMDCache
  alias FastestMCP.Auth.RedirectURI

  setup do
    CIMDCache.clear()
    :ok
  end

  test "cimd recognizes valid client id urls and rejects invalid ones" do
    assert CIMD.is_client_id?("https://example.com/client.json")
    assert CIMD.is_client_id?("https://example.com/path/to/client")

    refute CIMD.is_client_id?("https://example.com")
    refute CIMD.is_client_id?("https://example.com/")
    refute CIMD.is_client_id?("http://example.com/client.json")
    refute CIMD.is_client_id?("client-123")
  end

  test "cimd validates redirect uris with wildcard ports and loopback defaults" do
    document = %{
      "client_id" => "https://example.com/client.json",
      "redirect_uris" => [
        "http://localhost:*/callback",
        "http://127.0.0.1/callback"
      ]
    }

    assert {:ok, "http://localhost:32123/callback"} =
             CIMD.validate_redirect_uri(document, "http://localhost:32123/callback")

    assert {:ok, "http://127.0.0.1:4000/callback"} =
             CIMD.validate_redirect_uri(document, "http://127.0.0.1:4000/callback")

    assert {:error, :invalid_redirect_uri} =
             CIMD.validate_redirect_uri(document, "http://localhost:32123/other")

    assert {:error, :redirect_uri_required} = CIMD.default_redirect_uri(document)

    assert RedirectURI.matches_allowed_pattern?(
             "https://app.example.com/oauth/callback",
             "https://*.example.com/oauth/*"
           )

    refute RedirectURI.matches_allowed_pattern?(
             "http://localhost@evil.com/callback",
             "http://localhost:*"
           )
  end

  test "cimd fetch validates fetched metadata" do
    client_id = "https://example.com/client.json"
    mismatch_client_id = "https://example.com/mismatch-client.json"

    assert {:ok,
            %{"client_id" => ^client_id, "redirect_uris" => ["http://localhost:3000/callback"]}} =
             CIMD.fetch(client_id,
               cimd_fetcher: fn ^client_id ->
                 {:ok,
                  %{
                    "client_id" => client_id,
                    "redirect_uris" => ["http://localhost:3000/callback"],
                    "token_endpoint_auth_method" => "none"
                  }}
               end
             )

    assert {:error, "client_id mismatch"} =
             CIMD.fetch(mismatch_client_id,
               cimd_fetcher: fn ^mismatch_client_id ->
                 {:ok,
                  %{
                    "client_id" => "https://evil.example.com/client.json",
                    "redirect_uris" => ["http://localhost:3000/callback"]
                  }}
               end
             )
  end

  test "cimd caching honors max-age and etag revalidation" do
    client_id = "https://example.com/cache/client.json"
    call_counter = :counters.new(1, [])
    now = System.system_time(:millisecond)

    fetcher = fn
      ^client_id, [] ->
        :counters.add(call_counter, 1, 1)

        {:ok, 200,
         [
           {"cache-control", "max-age=0"},
           {"etag", "\"v1\""}
         ],
         %{
           "client_id" => client_id,
           "client_name" => "Cached App",
           "redirect_uris" => ["http://localhost:3000/callback"],
           "token_endpoint_auth_method" => "none"
         }}

      ^client_id, headers ->
        :counters.add(call_counter, 1, 1)
        assert {"if-none-match", "\"v1\""} in headers
        {:ok, 304, [{"cache-control", "max-age=120"}], nil}
    end

    assert {:ok, %{"client_name" => "Cached App"}} =
             CIMD.fetch(client_id, cimd_fetcher: fetcher, cimd_now_ms: now)

    assert {:ok, %{"client_name" => "Cached App"}} =
             CIMD.fetch(client_id, cimd_fetcher: fetcher, cimd_now_ms: now + 1)

    assert :counters.get(call_counter, 1) == 2

    assert {:ok, %{"client_name" => "Cached App"}} =
             CIMD.fetch(
               client_id,
               cimd_fetcher: fn _, _ -> flunk("expected fresh cached CIMD document") end,
               cimd_now_ms: now + 2
             )
  end

  test "cimd cache-control no-store prevents reuse" do
    client_id = "https://example.com/no-store/client.json"
    call_counter = :counters.new(1, [])

    fetcher = fn ^client_id, _headers ->
      :counters.add(call_counter, 1, 1)

      {:ok, 200, [{"cache-control", "no-store"}],
       %{
         "client_id" => client_id,
         "redirect_uris" => ["http://localhost:3000/callback"],
         "token_endpoint_auth_method" => "none"
       }}
    end

    assert {:ok, _document} = CIMD.fetch(client_id, cimd_fetcher: fetcher)
    assert {:ok, _document} = CIMD.fetch(client_id, cimd_fetcher: fetcher)
    assert :counters.get(call_counter, 1) == 2
  end

  test "cimd cache-control no-cache forces revalidation on each fetch" do
    client_id = "https://example.com/no-cache/client.json"
    call_counter = :counters.new(1, [])

    fetcher = fn
      ^client_id, [] ->
        :counters.add(call_counter, 1, 1)

        {:ok, 200,
         [
           {"cache-control", "no-cache"},
           {"etag", "\"v2\""}
         ],
         %{
           "client_id" => client_id,
           "redirect_uris" => ["http://localhost:3000/callback"],
           "token_endpoint_auth_method" => "none"
         }}

      ^client_id, headers ->
        :counters.add(call_counter, 1, 1)
        assert {"if-none-match", "\"v2\""} in headers
        {:ok, 304, [{"cache-control", "no-cache"}], nil}
    end

    assert {:ok, _document} = CIMD.fetch(client_id, cimd_fetcher: fetcher)
    assert {:ok, _document} = CIMD.fetch(client_id, cimd_fetcher: fetcher)
    assert :counters.get(call_counter, 1) == 2
  end

  test "cimd 304 without freshness headers preserves cached freshness lifetime" do
    client_id = "https://example.com/headerless-304/client.json"
    call_counter = :counters.new(1, [])
    now = System.system_time(:millisecond)

    fetcher = fn
      ^client_id, [] ->
        :counters.add(call_counter, 1, 1)

        {:ok, 200,
         [
           {"cache-control", "max-age=60"},
           {"etag", "\"v3\""}
         ],
         %{
           "client_id" => client_id,
           "redirect_uris" => ["http://localhost:3000/callback"],
           "token_endpoint_auth_method" => "none"
         }}

      ^client_id, headers ->
        :counters.add(call_counter, 1, 1)
        assert {"if-none-match", "\"v3\""} in headers
        {:ok, 304, [], nil}
    end

    assert {:ok, _document} = CIMD.fetch(client_id, cimd_fetcher: fetcher, cimd_now_ms: now)

    assert {:ok, _document} =
             CIMD.fetch(client_id, cimd_fetcher: fetcher, cimd_now_ms: now + 61_000)

    assert {:ok, _document} =
             CIMD.fetch(
               client_id,
               cimd_fetcher: fn _, _ ->
                 flunk("expected headerless 304 to refresh cached freshness")
               end,
               cimd_now_ms: now + 61_500
             )

    assert :counters.get(call_counter, 1) == 2
  end

  test "cimd validates jwks_uri with ssrf rules" do
    client_id = "https://example.com/jwks/client.json"

    assert {:error, reason} =
             CIMD.fetch(client_id,
               cimd_fetcher: fn ^client_id, _headers ->
                 {:ok, 200, [],
                  %{
                    "client_id" => client_id,
                    "redirect_uris" => ["http://localhost:3000/callback"],
                    "token_endpoint_auth_method" => "private_key_jwt",
                    "jwks_uri" => "https://internal.example.com/.well-known/jwks.json"
                  }}
               end,
               cimd_resolver: fn _, _ -> {:ok, ["192.168.1.10"]} end
             )

    assert reason =~ "jwks_uri failed SSRF validation"
  end
end
