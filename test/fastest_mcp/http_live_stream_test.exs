defmodule FastestMCP.HTTPLiveStreamTest do
  use ExUnit.Case, async: false

  alias FastestMCP.HTTP

  defmodule EarlyChunkPlug do
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(parent, {:early_chunk_request, self(), conn.method, conn.req_headers, body})

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream; charset=utf-8")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n"
        )

      send(parent, :early_chunk_sent)

      receive do
        :finish_early_chunk_response -> conn
      after
        2_000 -> conn
      end
    end
  end

  test "live POST streams deliver an early SSE chunk and cancel without leaking messages" do
    bandit =
      start_supervised!({Bandit, plug: {EarlyChunkPlug, parent: self()}, scheme: :http, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    assert {:ok, request_ref} =
             HTTP.stream_request(:post, "http://127.0.0.1:#{port}/mcp",
               json: %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"},
               headers: [{"accept", "text/event-stream"}],
               live_stream: true,
               timeout_ms: 1_000
             )

    assert {:fastest_mcp_mint_stream, relay_pid, _local_ref} = request_ref
    relay_monitor = Process.monitor(relay_pid)

    assert_receive {:early_chunk_request, server_pid, "POST", request_headers, request_body},
                   1_000

    assert {"content-type", "application/json"} in request_headers

    assert JSON.decode!(request_body) == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "method" => "ping"
           }

    assert_receive :early_chunk_sent, 1_000

    assert_receive {:http, {^request_ref, :stream_start, response_headers}}, 1_000
    assert {"content-type", "text/event-stream; charset=utf-8"} in response_headers

    assert_receive {:http, {^request_ref, :stream, chunk}}, 1_000
    assert chunk =~ ~s("id":7)

    assert :ok = HTTP.cancel_request(request_ref)
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay_pid, :normal}, 1_000

    send(server_pid, :finish_early_chunk_response)
    refute_receive {:http, {^request_ref, _message}}, 100
    refute_receive {:http, {^request_ref, _kind, _message}}, 100
  end
end
