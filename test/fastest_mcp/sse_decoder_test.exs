defmodule FastestMCP.SSEDecoderTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Transport.SSEDecoder

  test "decodes LF, CRLF, CR, and mixed event delimiters" do
    decoder = SSEDecoder.new()

    assert {:ok,
            [
              %{"line" => "lf"},
              %{"line" => "crlf"},
              %{"line" => "cr"},
              %{"line" => "mixed"}
            ], decoder} =
             SSEDecoder.feed(
               decoder,
               "data: {\"line\":\"lf\"}\n\n" <>
                 "data: {\"line\":\"crlf\"}\r\n\r\n" <>
                 "data: {\"line\":\"cr\"}\r\r" <>
                 "data: {\"line\":\"mixed\"}\r\n\n"
             )

    assert :ok = SSEDecoder.finish(decoder)
  end

  test "joins multiline data fields before decoding JSON" do
    decoder = SSEDecoder.new()

    assert {:ok, [%{"nested" => %{"ok" => true}}], decoder} =
             SSEDecoder.feed(
               decoder,
               "data: {\ndata: \"nested\": {\"ok\": true}\ndata: }\n\n"
             )

    assert :ok = SSEDecoder.finish(decoder)
  end

  test "retains event ids and retry intervals for HTTP stream resumption" do
    assert {:ok, [%{"sequence" => 1}], decoder} =
             SSEDecoder.feed(
               SSEDecoder.new(),
               "id: stream-a:1\nretry: 1500\nevent: message\ndata: {\"sequence\":1}\n\n"
             )

    assert SSEDecoder.last_event_id(decoder) == "stream-a:1"
    assert SSEDecoder.retry_ms(decoder) == 1_500

    assert {:ok, [%{"sequence" => 2}], decoder} =
             SSEDecoder.feed(decoder, "data: {\"sequence\":2}\n\n")

    assert SSEDecoder.last_event_id(decoder) == "stream-a:1"
    assert SSEDecoder.retry_ms(decoder) == 1_500

    assert {:ok, [], decoder} =
             SSEDecoder.feed(decoder, "id: stream-a:primed\nretry: 2500\ndata:\n\n")

    assert SSEDecoder.last_event_id(decoder) == "stream-a:primed"
    assert SSEDecoder.retry_ms(decoder) == 2_500
  end

  test "ignores invalid retry fields and event ids containing null bytes" do
    decoder = %{SSEDecoder.new() | last_event_id: "stream-a:1", retry_ms: 1_000}

    assert {:ok, [%{"ok" => true}], decoder} =
             SSEDecoder.feed(
               decoder,
               "id: bad\0id\nretry: 1.5\ndata: {\"ok\":true}\n\n"
             )

    assert SSEDecoder.last_event_id(decoder) == "stream-a:1"
    assert SSEDecoder.retry_ms(decoder) == 1_000
  end

  test "parses retry without constructing unbounded integers" do
    assert {:ok, [], zero} =
             SSEDecoder.feed(SSEDecoder.new(), "retry: #{String.duplicate("0", 10_000)}\n\n")

    assert SSEDecoder.retry_ms(zero) == 0

    assert {:ok, [], bounded} =
             SSEDecoder.feed(SSEDecoder.new(), "retry: 4294967295\n\n")

    assert SSEDecoder.retry_ms(bounded) == 4_294_967_295

    assert {:ok, [], saturated} =
             SSEDecoder.feed(
               SSEDecoder.new(max_event_bytes: 20_000),
               "retry: #{String.duplicate("9", 10_000)}\n\n"
             )

    assert SSEDecoder.retry_ms(saturated) == :infinity
  end

  test "suppresses replayed data events by event id while retaining later ids" do
    decoder = SSEDecoder.new(max_seen_event_ids: 2)

    assert {:ok, [%{"sequence" => 1}], decoder} =
             SSEDecoder.feed(decoder, "id: one\ndata: {\"sequence\":1}\n\n")

    assert {:ok, [], decoder} =
             SSEDecoder.feed(decoder, "id: one\ndata: {\"sequence\":1}\n\n")

    assert {:ok, [%{"sequence" => 2}, %{"sequence" => 3}], decoder} =
             SSEDecoder.feed(
               decoder,
               "id: two\ndata: {\"sequence\":2}\n\nid: three\ndata: {\"sequence\":3}\n\n"
             )

    assert {:ok, [%{"sequence" => 1}], _decoder} =
             SSEDecoder.feed(decoder, "id: one\ndata: {\"sequence\":1}\n\n")
  end

  test "decodes events fragmented at every byte boundary" do
    encoded =
      "id: 1\r\nevent: message\r\ndata: {\"first\":1}\r\n\r\n" <>
        "data: {\ndata: \"second\":2\ndata: }\n\n"

    {events, decoder} =
      encoded
      |> :binary.bin_to_list()
      |> Enum.reduce({[], SSEDecoder.new()}, fn byte, {events, decoder} ->
        assert {:ok, decoded, decoder} = SSEDecoder.feed(decoder, <<byte>>)
        {events ++ decoded, decoder}
      end)

    assert events == [%{"first" => 1}, %{"second" => 2}]
    assert :ok = SSEDecoder.finish(decoder)
  end

  test "ignores a UTF-8 byte-order mark even when it is fragmented" do
    assert {:ok, [], decoder} = SSEDecoder.feed(SSEDecoder.new(), <<0xEF>>)
    assert {:ok, [], decoder} = SSEDecoder.feed(decoder, <<0xBB>>)

    assert {:ok, [%{"ready" => true}], decoder} =
             SSEDecoder.feed(decoder, <<0xBF>> <> "data: {\"ready\":true}\n\n")

    assert :ok = SSEDecoder.finish(decoder)
  end

  test "ignores empty priming data and comment-only events" do
    decoder = SSEDecoder.new()

    assert {:ok, [%{"ready" => true}], decoder} =
             SSEDecoder.feed(
               decoder,
               ": connected\n\ndata:\n\ndata: {\"ready\":true}\n\n"
             )

    assert :ok = SSEDecoder.finish(decoder)
  end

  test "rejects an oversized unterminated event before a delimiter arrives" do
    decoder = SSEDecoder.new(max_event_bytes: 8)

    assert {:error, error} = SSEDecoder.feed(decoder, "data: 123")
    assert error.code == :bad_request
    assert error.message == "SSE event exceeds configured size limit"
    assert error.details == %{max_event_bytes: 8}
  end

  test "rejects an oversized complete event even when the delimiter is present" do
    decoder = SSEDecoder.new(max_event_bytes: 7)

    assert {:error, error} = SSEDecoder.feed(decoder, "data: {}\n\n")
    assert error.code == :bad_request
    assert error.message == "SSE event exceeds configured size limit"
    assert error.details == %{max_event_bytes: 7}
  end

  test "reports malformed JSON data" do
    assert {:error, error} = SSEDecoder.feed(SSEDecoder.new(), "data: {nope}\n\n")
    assert error.code == :bad_request
    assert error.message == "SSE data is not valid JSON"
    assert is_binary(error.details.reason)
  end

  test "finish accepts trailing whitespace and rejects an incomplete event" do
    assert :ok = SSEDecoder.finish(%{SSEDecoder.new() | buffer: " \r\n\t"})

    assert {:ok, [], decoder} = SSEDecoder.feed(SSEDecoder.new(), "data: {\"pending\":true}")
    assert {:error, error} = SSEDecoder.finish(decoder)
    assert error.code == :bad_request
    assert error.message == "SSE stream ended with an incomplete event"

    assert {:ok, [], partial_bom} = SSEDecoder.feed(SSEDecoder.new(), <<0xEF>>)
    assert {:error, %FastestMCP.Error{code: :bad_request}} = SSEDecoder.finish(partial_bom)
  end
end

defmodule FastestMCP.TestSupport.PrimedSSEPlug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)

    case request["method"] do
      "initialize" ->
        payload = %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "protocolVersion" => FastestMCP.Protocol.current_version(),
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "primed-sse", "version" => "1.0.0"}
          }
        }

        conn
        |> put_resp_header("mcp-session-id", "primed-sse-session")
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(payload))

      "notifications/initialized" ->
        send_resp(conn, 202, "")

      "tools/list" ->
        payload = %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]
          }
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(payload))

      "tools/call" ->
        payload = %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "content" => [%{"type" => "text", "text" => "primed"}],
            "structuredContent" => %{"primed" => true}
          }
        }

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        {:ok, conn} = chunk(conn, "data:\n\n")
        {:ok, conn} = chunk(conn, "event: message\ndata: #{JSON.encode!(payload)}\n\n")
        conn
    end
  end
end

defmodule FastestMCP.SSEClientCleanupTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client

  test "terminal JSON responses end streamed calls without delaying reuse or disconnect" do
    server_name = "sse-terminal-response-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
            json_response: true},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp", timeout_ms: 5_000)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"sequence" => 1} = Client.call_tool(client, "echo", %{"sequence" => 1})
    assert %{"sequence" => 2} = Client.call_tool(client, "echo", %{"sequence" => 2})

    bounded_client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        timeout_ms: 5_000,
        max_sse_event_bytes: 512
      )

    on_exit(fn ->
      if Client.connected?(bounded_client), do: Client.disconnect(bounded_client)
    end)

    bounded_error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool(bounded_client, "echo", %{"payload" => String.duplicate("x", 2_048)})
      end

    assert bounded_error.code == :bad_request
    assert bounded_error.message == "streamed JSON response exceeds configured size limit"
    assert :ok = Client.disconnect(bounded_client)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Client.disconnect(client)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "HTTP POST streams ignore an empty priming data event before the result" do
    bandit =
      start_supervised!(
        {Bandit, plug: FastestMCP.TestSupport.PrimedSSEPlug, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"structuredContent" => %{"primed" => true}} =
             Client.call_tool(client, "echo", %{})
  end
end
