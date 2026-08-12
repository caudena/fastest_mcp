defmodule FastestMCP.ClientSessionRecoveryTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Error

  defmodule RecoveryPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)

      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} -> handle_post(conn, state, test_pid)
        {"GET", "/mcp"} -> handle_session_stream(conn, state, test_pid)
        _other -> send_resp(conn, 404, "not found")
      end
    end

    defp handle_post(conn, state, test_pid) do
      {:ok, body, conn} = read_body(conn)
      payload = JSON.decode!(body)
      session_id = conn |> get_req_header("mcp-session-id") |> List.first()

      case payload do
        %{"method" => "initialize", "id" => id} ->
          {initialize_count, recovered_session_id} =
            Agent.get_and_update(state, fn current ->
              count = Map.get(current, :initialize_count, 0) + 1
              session_id = "recovery-session-#{count}"

              next =
                current
                |> Map.put(:initialize_count, count)
                |> Map.update(:initialize_session_headers, [session_id], &[session_id | &1])

              {{count, session_id}, next}
            end)

          send(test_pid, {:initialize_request, initialize_count, session_id})

          response = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "protocolVersion" => FastestMCP.Protocol.current_version(),
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{
                "name" => "recovery-server-#{initialize_count}",
                "version" => "1.0.0"
              }
            }
          }

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("mcp-session-id", recovered_session_id)
          |> send_resp(200, JSON.encode!(response))

        %{"method" => "notifications/initialized"} ->
          Agent.update(state, fn current ->
            Map.update(current, :initialized_sessions, [session_id], &[session_id | &1])
          end)

          send_resp(conn, 202, "")

        %{"method" => "tools/list", "id" => id} ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "tools" => [
                %{
                  "name" => "charge_card",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"amount" => %{"type" => "number"}},
                    "required" => ["amount"]
                  }
                }
              ]
            }
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(response))

        %{"method" => "tools/call"} ->
          Agent.update(state, fn current ->
            current
            |> Map.update(:tool_call_count, 1, &(&1 + 1))
            |> Map.update(:tool_call_sessions, [session_id], &[session_id | &1])
          end)

          send_resp(conn, 404, "session not found")

        %{"method" => "ping", "id" => id} ->
          Agent.update(state, fn current ->
            Map.update(current, :ping_sessions, [session_id], fn sessions ->
              [session_id | sessions]
            end)
          end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}))

        _other ->
          send_resp(conn, 202, "")
      end
    end

    defp handle_session_stream(conn, state, test_pid) do
      last_event_id = conn |> get_req_header("last-event-id") |> List.first()
      session_id = conn |> get_req_header("mcp-session-id") |> List.first()

      {mode, connection_number} =
        Agent.get_and_update(state, fn current ->
          connection_number = Map.get(current, :stream_connections, 0) + 1

          next =
            current
            |> Map.put(:stream_connections, connection_number)
            |> Map.update(:last_event_ids, [last_event_id], &[last_event_id | &1])
            |> Map.update(:stream_session_ids, [session_id], &[session_id | &1])

          {{Map.fetch!(current, :mode), connection_number}, next}
        end)

      send(test_pid, {:session_stream_request, connection_number, last_event_id})

      case {mode, connection_number} do
        {:reconnect, 1} ->
          conn
          |> begin_event_stream()
          |> write_event("event-1", "one", retry: 10)

        {:reconnect, 2} ->
          conn
          |> begin_event_stream()
          |> write_event("event-1", "duplicate")
          |> write_event("event-2", "two")

        {:deleted, 1} ->
          conn
          |> begin_event_stream()
          |> write_event("deleted-event-1", "before-delete")

        {:deleted, 2} ->
          send_resp(conn, 404, "session deleted")

        {:deleted, 3} ->
          send_resp(conn, 404, "replacement session deleted")

        {:get_recovery, 1} ->
          send_resp(conn, 404, "session missing")

        {:get_recovery, 2} ->
          conn
          |> begin_event_stream()
          |> write_event("replacement-event-1", "after-recovery")

        {:invalid_media, 1} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(%{"not" => "an event stream"}))

        _other ->
          send_resp(conn, 500, "unexpected reconnect")
      end
    end

    defp begin_event_stream(conn) do
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
    end

    defp write_event(conn, event_id, data, opts \\ []) do
      payload = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "info", "data" => data}
      }

      encoded =
        [
          "id: ",
          event_id,
          "\n",
          if(opts[:retry], do: ["retry: ", Integer.to_string(opts[:retry]), "\n"], else: []),
          "data: ",
          JSON.encode!(payload),
          "\n\n"
        ]

      {:ok, conn} = chunk(conn, encoded)
      conn
    end
  end

  test "a 404 session miss reinitializes without replaying the original request" do
    {client, state} = start_client(:recovery)

    assert Client.session_id(client) == "recovery-session-1"

    error =
      assert_raise Error, fn ->
        Client.call_tool(client, "charge_card", %{"amount" => 10})
      end

    assert error.code == :bad_request
    assert error.details.session_recovered
    refute error.details.original_request_replayed

    assert_receive {:initialize_request, 1, nil}, 1_000
    assert_receive {:initialize_request, 2, nil}, 1_000

    assert Client.session_id(client) == "recovery-session-2"

    assert get_in(Client.initialize_result(client), ["serverInfo", "name"]) ==
             "recovery-server-2"

    assert %{} = Client.ping(client)

    snapshot = Agent.get(state, & &1)
    assert snapshot.initialize_count == 2
    assert snapshot.tool_call_count == 1
    assert snapshot.tool_call_sessions == ["recovery-session-1"]
    assert snapshot.ping_sessions == ["recovery-session-2"]

    assert Enum.sort(snapshot.initialized_sessions) ==
             ["recovery-session-1", "recovery-session-2"]
  end

  test "session GET reconnects with Last-Event-ID, uses retry, deduplicates, and stops at bound" do
    {client, state} =
      start_client(:reconnect,
        sse_reconnect: [max_attempts: 1, min_retry_ms: 0, max_retry_ms: 10]
      )

    assert :ok = Client.open_session_stream(client)

    assert_receive {:session_stream_request, 1, nil}, 1_000
    assert_receive {:stream_message, "one"}, 1_000
    assert_receive {:session_stream_request, 2, "event-1"}, 1_000
    assert_receive {:stream_message, "two"}, 1_000
    refute_receive {:stream_message, "duplicate"}, 100

    wait_for_session_stream_to_close(client)
    Process.sleep(25)

    snapshot = Agent.get(state, & &1)
    assert snapshot.stream_connections == 2
    assert Enum.reverse(snapshot.last_event_ids) == [nil, "event-1"]
  end

  test "session GET recovers a deleted stale session once and stops on a closed replacement" do
    {client, state} =
      start_client(:deleted,
        sse_reconnect: [max_attempts: 5, min_retry_ms: 0, max_retry_ms: 0]
      )

    assert :ok = Client.open_session_stream(client)

    assert_receive {:stream_message, "before-delete"}, 1_000
    assert_receive {:session_stream_request, 2, "deleted-event-1"}, 1_000
    assert_receive {:initialize_request, 2, nil}, 1_000
    assert_receive {:session_stream_request, 3, nil}, 1_000

    wait_for_session_stream_to_close(client)
    Process.sleep(25)

    snapshot = Agent.get(state, & &1)
    assert snapshot.initialize_count == 2
    assert snapshot.stream_connections == 3

    assert Enum.reverse(snapshot.stream_session_ids) == [
             "recovery-session-1",
             "recovery-session-1",
             "recovery-session-2"
           ]
  end

  test "a standalone session GET 404 recovers once and opens the replacement stream" do
    {client, state} = start_client(:get_recovery, sse_reconnect: false)

    assert :ok = Client.open_session_stream(client)

    assert_receive {:session_stream_request, 1, nil}, 1_000
    assert_receive {:initialize_request, 2, nil}, 1_000
    assert_receive {:session_stream_request, 2, nil}, 1_000
    assert_receive {:stream_message, "after-recovery"}, 1_000

    assert Client.session_id(client) == "recovery-session-2"

    assert get_in(Client.initialize_result(client), ["serverInfo", "name"]) ==
             "recovery-server-2"

    wait_for_session_stream_to_close(client)

    snapshot = Agent.get(state, & &1)
    assert snapshot.initialize_count == 2
    assert snapshot.stream_connections == 2

    assert Enum.reverse(snapshot.stream_session_ids) ==
             ["recovery-session-1", "recovery-session-2"]
  end

  test "a standalone session GET rejects a non-SSE response media type" do
    {client, state} = start_client(:invalid_media, sse_reconnect: false)

    error =
      assert_raise Error, fn ->
        Client.open_session_stream(client)
      end

    assert error.code == :bad_request
    assert error.message == "HTTP MCP response has an unsupported Content-Type"
    assert error.details.content_type == "application/json; charset=utf-8"
    assert Agent.get(state, & &1).stream_connections == 1
  end

  defp start_client(mode, opts \\ []) do
    state = start_supervised!({Agent, fn -> %{mode: mode} end})

    bandit =
      start_supervised!(
        {Bandit, plug: {RecoveryPlug, state: state, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    parent = self()

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        Keyword.merge(
          [
            notification_handler: fn
              %{"method" => "notifications/message", "params" => %{"data" => data}} ->
                send(parent, {:stream_message, data})

              _message ->
                :ok
            end
          ],
          opts
        )
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    {client, state}
  end

  defp wait_for_session_stream_to_close(client, attempts \\ 100)

  defp wait_for_session_stream_to_close(_client, 0),
    do: flunk("session stream did not stop")

  defp wait_for_session_stream_to_close(client, attempts) do
    if Client.session_stream_open?(client) or :sys.get_state(client.pid).session_stream do
      Process.sleep(10)
      wait_for_session_stream_to_close(client, attempts - 1)
    else
      :ok
    end
  end
end
