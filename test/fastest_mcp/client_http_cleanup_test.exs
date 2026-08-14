defmodule FastestMCP.ClientHTTPCleanupTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Error

  defmodule JSONRPCPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"id" => id} = JSON.decode!(body)

      response = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response)
    end
  end

  test "timed out request cancels its live HTTP request" do
    {url, server_ref} = start_hanging_server()

    client =
      Client.connect!(url, auto_initialize: false, protocol_version: "2025-11-25")

    mark_initialized(client)
    on_exit(fn -> disconnect_if_alive(client) end)

    request_task =
      Task.async(fn ->
        capture_client_result(fn -> Client.ping(client, timeout_ms: 500) end)
      end)

    entry = wait_for_request_entry(client)
    refute is_nil(entry.request_ref)
    assert_receive {:raw_http_request, ^server_ref, _request}, 1_000

    assert {:error, %Error{code: :timeout}} = Task.await(request_task, 1_000)
    assert_receive {:raw_http_closed, ^server_ref}, 750
    assert :sys.get_state(client.pid).in_flight == %{}
    assert Client.connected?(client)
  end

  test "disconnect cancels an in-flight request and tears down promptly" do
    {url, server_ref} = start_hanging_server()

    client =
      Client.connect!(url, auto_initialize: false, protocol_version: "2025-11-25")

    mark_initialized(client)

    request_task =
      Task.async(fn ->
        capture_client_result(fn -> Client.ping(client, timeout_ms: 5_000) end)
      end)

    assert_receive {:raw_http_request, ^server_ref, _request}, 1_000
    %{worker_pid: worker_pid, request_ref: request_ref} = wait_for_request_entry(client)
    refute is_nil(request_ref)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Client.disconnect(client)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 500
    assert_receive {:raw_http_closed, ^server_ref}, 750
    refute Process.alive?(worker_pid)
    assert {:exit, _reason} = Task.await(request_task, 1_000)
  end

  test "killing a request worker cannot leak its HTTP request" do
    {url, server_ref} = start_hanging_server()

    client =
      Client.connect!(url, auto_initialize: false, protocol_version: "2025-11-25")

    mark_initialized(client)
    on_exit(fn -> disconnect_if_alive(client) end)

    request_task =
      Task.async(fn ->
        capture_client_result(fn -> Client.ping(client, timeout_ms: 5_000) end)
      end)

    assert_receive {:raw_http_request, ^server_ref, _request}, 1_000
    %{worker_pid: worker_pid, request_ref: request_ref} = wait_for_request_entry(client)
    refute is_nil(request_ref)

    Process.exit(worker_pid, :kill)

    assert {:error, %Error{code: :internal_error}} = Task.await(request_task, 1_000)
    assert_receive {:raw_http_closed, ^server_ref}, 750
    assert :sys.get_state(client.pid).in_flight == %{}
  end

  test "disconnect cancels the long-lived session stream promptly" do
    {url, server_ref} = start_hanging_server(:event_stream)

    client =
      Client.connect!(url, auto_initialize: false, protocol_version: "2025-11-25")

    mark_initialized(client)

    assert :ok = Client.open_session_stream(client)
    assert_receive {:raw_http_request, ^server_ref, _request}, 1_000

    session_stream = wait_for_session_stream_request(client)
    assert session_stream.started?
    refute is_nil(session_stream.request_ref)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Client.disconnect(client)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 500
    assert_receive {:raw_http_closed, ^server_ref}, 750
    refute Process.alive?(session_stream.pid)
  end

  test "repeated HTTP requests do not create atoms after warmup" do
    bandit =
      start_supervised!({Bandit, plug: JSONRPCPlug, scheme: :http, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        auto_initialize: false,
        protocol_version: "2025-11-25"
      )

    mark_initialized(client)
    on_exit(fn -> disconnect_if_alive(client) end)

    for _iteration <- 1..3 do
      assert %{"ok" => true} = Client.ping(client)
    end

    atom_count = :erlang.system_info(:atom_count)

    for _iteration <- 1..25 do
      assert %{"ok" => true} = Client.ping(client)
    end

    assert :erlang.system_info(:atom_count) == atom_count
  end

  defp start_hanging_server(response_mode \\ :none) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    parent = self()
    server_ref = make_ref()

    server_pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = receive_http_request(socket)
        send(parent, {:raw_http_request, server_ref, request})
        maybe_send_response(socket, response_mode)
        wait_for_socket_close(socket, parent, server_ref)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
    end)

    {"http://127.0.0.1:#{port}/mcp", server_ref}
  end

  defp receive_http_request(socket, buffer \\ "") do
    case complete_http_request(buffer) do
      {:ok, request} ->
        {:ok, request}

      :more ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, chunk} -> receive_http_request(socket, buffer <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp complete_http_request(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {headers_end, 4} ->
        body_start = headers_end + 4
        headers = binary_part(buffer, 0, headers_end)
        content_length = content_length(headers)
        request_size = body_start + content_length

        if byte_size(buffer) >= request_size do
          {:ok, binary_part(buffer, 0, request_size)}
        else
          :more
        end

      :nomatch ->
        :more
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  defp maybe_send_response(_socket, :none), do: :ok

  defp maybe_send_response(socket, :event_stream) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\n" <>
          "content-type: text/event-stream\r\n" <>
          "transfer-encoding: chunked\r\n" <>
          "connection: keep-alive\r\n\r\n" <>
          "3\r\n:\n\n\r\n"
      )
  end

  defp wait_for_socket_close(socket, parent, server_ref) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, _data} ->
        wait_for_socket_close(socket, parent, server_ref)

      {:error, :closed} ->
        send(parent, {:raw_http_closed, server_ref})

      {:error, reason} ->
        send(parent, {:raw_http_close_error, server_ref, reason})
    end
  end

  defp wait_for_request_entry(client, attempts \\ 100)

  defp wait_for_request_entry(_client, 0), do: flunk("HTTP request reference was not stored")

  defp wait_for_request_entry(client, attempts) do
    entry =
      client.pid
      |> :sys.get_state()
      |> Map.fetch!(:in_flight)
      |> Map.values()
      |> Enum.find(&(not is_nil(Map.get(&1, :request_ref))))

    if entry do
      entry
    else
      Process.sleep(5)
      wait_for_request_entry(client, attempts - 1)
    end
  end

  defp wait_for_session_stream_request(client, attempts \\ 100)

  defp wait_for_session_stream_request(_client, 0),
    do: flunk("session stream HTTP request reference was not stored")

  defp wait_for_session_stream_request(client, attempts) do
    session_stream = :sys.get_state(client.pid).session_stream

    if is_map(session_stream) and not is_nil(Map.get(session_stream, :request_ref)) do
      session_stream
    else
      Process.sleep(5)
      wait_for_session_stream_request(client, attempts - 1)
    end
  end

  defp capture_client_result(fun) do
    {:ok, fun.()}
  rescue
    error in Error -> {:error, error}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp disconnect_if_alive(client) do
    if Client.connected?(client), do: Client.disconnect(client)
  end

  defp mark_initialized(client) do
    :sys.replace_state(client.pid, fn state ->
      %{
        state
        | lifecycle_state: :initialized,
          initialize_result: %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "cleanup-test", "version" => "1.0.0"}
          },
          advertised_client_capabilities: %{}
      }
    end)

    :ok
  end
end
