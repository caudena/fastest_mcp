defmodule FastestMCP.StreamableHTTPSupervisionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "JSON response requests execute under the runtime task supervisor" do
    parent = self()
    server_name = unique_server_name("json-supervision")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server)
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
    server_name = unique_server_name("json-timeout")
    timeout_ms = 50

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:timeout_handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server)
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
    response = Task.await(request, 1_000)

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

  test "cancellation suppresses a JSON response and unregisters its dispatch" do
    parent = self()
    server_name = unique_server_name("json-cancellation")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
        send(parent, {:cancel_handler_started, self()})

        receive do
          :release_handler -> %{released: true}
        end
      end)

    start_server!(server)
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

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server, session_idle_ttl: :infinity)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp assert_active_requests_empty(server_name, session_id) do
    assert_eventually(fn ->
      case Registry.lookup_session(server_name, session_id) do
        {:ok, session_pid} -> :sys.get_state(session_pid).active_requests == %{}
        _other -> false
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp unique_server_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
