defmodule FastestMCP.StreamableHTTPSupervisionTest do
  use FastestMCP.Case, async: true

  import Plug.Test

  alias FastestMCP.Context
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

  defmodule DisconnectingAdapter do
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: TestAdapter

    @impl true
    def send_chunked(state, status, headers),
      do: TestAdapter.send_chunked(state, status, headers)

    @impl true
    def chunk(%{successful_chunks: successful_chunks} = state, body)
        when successful_chunks > 0 do
      {:ok, response_body, state} = TestAdapter.chunk(state, body)
      send(state.disconnect_target, {:stream_chunk_written, IO.iodata_to_binary(body)})
      {:ok, response_body, %{state | successful_chunks: successful_chunks - 1}}
    end

    def chunk(%{disconnect_target: target} = _state, _body) do
      send(target, :stream_chunk_disconnected)
      {:error, :closed}
    end

    @impl true
    defdelegate send_resp(state, status, headers, body), to: TestAdapter

    @impl true
    defdelegate send_file(state, status, headers, path, offset, length), to: TestAdapter

    @impl true
    defdelegate read_req_body(state, opts), to: TestAdapter

    @impl true
    defdelegate inform(state, status, headers), to: TestAdapter

    @impl true
    defdelegate upgrade(state, protocol, opts), to: TestAdapter

    @impl true
    defdelegate push(state, path, headers), to: TestAdapter

    @impl true
    defdelegate get_peer_data(state), to: TestAdapter

    @impl true
    defdelegate get_sock_data(state), to: TestAdapter

    @impl true
    defdelegate get_ssl_data(state), to: TestAdapter

    @impl true
    defdelegate get_http_protocol(state), to: TestAdapter
  end

  test "JSON response requests execute under the runtime task supervisor" do
    parent = self()
    server_name = unique_name("json-supervision")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server, session_idle_ttl: :infinity)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    request =
      Task.async(fn ->
        ProtocolTest.http_request(
          server_name,
          session_id,
          10,
          "tools/call",
          %{"name" => "blocked", "arguments" => %{}},
          json_response: true
        )
      end)

    assert_receive {:handler_started, handler_pid}, 1_000

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 1
    end)

    send(handler_pid, :release_handler)
    response = Task.await(request, 1_000)

    assert response.status == 200
    assert %{"jsonrpc" => "2.0", "id" => 10, "result" => %{}} = JSON.decode!(response.resp_body)

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 0
    end)

    assert_active_requests_empty(server_name, session_id)
  end

  test "JSON response timeout terminates and unregisters the supervised dispatch" do
    parent = self()
    server_name = unique_name("json-timeout")
    timeout_ms = 500

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:timeout_handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server, session_idle_ttl: :infinity)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    request =
      Task.async(fn ->
        ProtocolTest.http_request(
          server_name,
          session_id,
          11,
          "tools/call",
          %{"name" => "blocked", "arguments" => %{}},
          json_response: true,
          stream_request_timeout_ms: timeout_ms
        )
      end)

    assert_receive {:timeout_handler_started, handler_pid}, 1_000
    response = Task.await(request, 5_000)

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 11,
             "error" => %{
               "message" => "request timed out",
               "data" => %{
                 "fastestmcp" => %{
                   "code" => "timeout",
                   "details" => %{"timeout_ms" => ^timeout_ms}
                 }
               }
             }
           } = JSON.decode!(response.resp_body)

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 0
    end)

    assert_active_requests_empty(server_name, session_id)
    send(handler_pid, :release_handler)
  end

  test "a streamed POST timeout terminates its supervised dispatch and emits an SSE error" do
    parent = self()
    server_name = unique_name("timed-out-post")
    stream_timeout_ms = 1_000

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("wait_forever", fn _arguments, _context ->
        send(parent, {:stream_timeout_operation_started, self()})

        receive do
          :finish_timed_out_operation -> %{finished: true}
        end
      end)

    start_server!(server, session_idle_ttl: :infinity)

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    request_task =
      Task.async(fn ->
        ProtocolTest.http_request(
          server_name,
          session_id,
          8,
          "tools/call",
          %{"name" => "wait_forever", "arguments" => %{}},
          json_response: false,
          stream_request_timeout_ms: stream_timeout_ms
        )
      end)

    assert_receive {:stream_timeout_operation_started, operation_pid}, 1_000

    assert [dispatch_pid] =
             runtime.stream_task_supervisor
             |> DynamicSupervisor.which_children()
             |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

    dispatch_monitor = Process.monitor(dispatch_pid)
    response = Task.await(request_task, 5_000)

    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch_pid, _reason}, 1_000
    assert response.status == 200
    assert response.state == :chunked
    assert Plug.Conn.get_resp_header(response, "content-type") == ["text/event-stream"]

    assert %{
             "jsonrpc" => "2.0",
             "id" => 8,
             "error" => %{
               "code" => -32_001,
               "message" => "streamed request timed out",
               "data" => %{
                 "fastestmcp" => %{
                   "code" => "timeout",
                   "details" => %{"timeout_ms" => ^stream_timeout_ms}
                 }
               }
             }
           } = ProtocolTest.sse_message(response.resp_body)

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 0
    end)

    send(operation_pid, :finish_timed_out_operation)
  end

  test "cancellation suppresses a JSON response and unregisters its dispatch" do
    parent = self()
    server_name = unique_name("json-cancellation")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:cancel_handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server, session_idle_ttl: :infinity)
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    request =
      Task.async(fn ->
        ProtocolTest.http_request(
          server_name,
          session_id,
          12,
          "tools/call",
          %{"name" => "blocked", "arguments" => %{}},
          json_response: true
        )
      end)

    assert_receive {:cancel_handler_started, handler_pid}, 1_000

    cancellation =
      ProtocolTest.http_post(
        server_name,
        session_id,
        ProtocolTest.jsonrpc_notification("notifications/cancelled", %{
          "requestId" => 12,
          "reason" => "test cancellation"
        }),
        json_response: true
      )

    assert cancellation.status == 202
    assert cancellation.resp_body == ""

    response = Task.await(request, 1_000)
    assert response.status == 202
    assert response.resp_body == ""

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 0
    end)

    assert_active_requests_empty(server_name, session_id)
    send(handler_pid, :release_handler)
  end

  test "a POST disconnect retains result coordination without cancelling the operation" do
    parent = self()
    server_name = unique_name("detached-post")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("detached", fn _arguments, context ->
        send(parent, {:detached_operation_started, self()})

        {:ok, _delivery} =
          Context.send_notification(context, "notifications/detached-test")

        {:ok, _delivery} =
          Context.send_notification(context, "notifications/detached-test-2")

        receive do
          :finish_detached_operation ->
            send(parent, :detached_operation_finished)
            %{finished: true}
        end
      end)

    start_server!(server, session_idle_ttl: :infinity)

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    request_task =
      Task.async(fn ->
        :post
        |> conn(
          "/mcp",
          JSON.encode!(
            ProtocolTest.jsonrpc_request(7, "tools/call", %{
              "name" => "detached",
              "arguments" => %{}
            })
          )
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("mcp-session-id", session_id)
        |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
        |> disconnect_after_chunks(1, parent)
        |> StreamableHTTP.call(server_name: server_name)
      end)

    assert_receive {:stream_chunk_written, cursor_frame}
    assert_receive :stream_chunk_disconnected
    assert_receive {:detached_operation_started, operation_pid}
    assert Process.alive?(operation_pid)
    assert Task.yield(request_task, 0) == nil

    [last_event_id] = Regex.run(~r/^id: ([^\n]+)$/m, cursor_frame, capture: :all_but_first)

    assert DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 1
    assert DynamicSupervisor.count_children(runtime.call_supervisor).active == 1

    send(operation_pid, :finish_detached_operation)
    assert_receive :detached_operation_finished, 1_000
    assert %Plug.Conn{state: :chunked} = Task.await(request_task, 1_000)

    assert {:ok, %{sink_ref: resumed_sink, resumed?: true, replayed: 3}} =
             Session.attach_sink(server_name, session_id, self(),
               kind: :get,
               last_event_id: last_event_id
             )

    assert_receive {:fastest_mcp_session_message, ^resumed_sink, _event_id,
                    %{"jsonrpc" => "2.0", "id" => 7, "result" => result}},
                   1_000

    assert is_map(result)
    assert_receive {:fastest_mcp_session_cursor, ^resumed_sink, _cursor}
    assert :ok = Session.detach_sink(server_name, session_id, resumed_sink)

    assert_eventually(fn ->
      DynamicSupervisor.count_children(runtime.stream_task_supervisor).active == 0 and
        DynamicSupervisor.count_children(runtime.call_supervisor).active == 0
    end)
  end

  defp assert_active_requests_empty(server_name, session_id) do
    assert_eventually(fn ->
      case Registry.lookup_session(server_name, session_id) do
        {:ok, session_pid} -> :sys.get_state(session_pid).active_requests == %{}
        _other -> false
      end
    end)
  end

  defp disconnect_after_chunks(
         %Plug.Conn{adapter: {Plug.Adapters.Test.Conn, state}} = conn,
         successful_chunks,
         disconnect_target
       ) do
    state =
      Map.merge(state, %{
        disconnect_target: disconnect_target,
        successful_chunks: successful_chunks
      })

    %{conn | adapter: {DisconnectingAdapter, state}}
  end
end
