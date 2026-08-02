defmodule FastestMCP.SSEDecoderTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Transport.SSEDecoder

  test "decodes LF and CRLF event delimiters" do
    decoder = SSEDecoder.new()

    assert {:ok, [%{"line" => "lf"}, %{"line" => "crlf"}], decoder} =
             SSEDecoder.feed(
               decoder,
               "data: {\"line\":\"lf\"}\n\ndata: {\"line\":\"crlf\"}\r\n\r\n"
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
            "capabilities" => %{},
            "serverInfo" => %{"name" => "primed-sse", "version" => "1.0.0"}
          }
        }

        conn
        |> put_resp_header("mcp-session-id", "primed-sse-session")
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(payload))

      "notifications/initialized" ->
        send_resp(conn, 202, "")

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
            server_name: server_name, unsafe_allow_any_host: true, json_response: true},
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
