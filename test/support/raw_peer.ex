defmodule FastestMCP.TestSupport.RawPeer do
  @moduledoc false

  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.TestSupport.RawPeer.Input
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StdioAdapter

  defstruct [
    :transport,
    :server_name,
    :session_id,
    :bandit,
    :port,
    :socket,
    :post_socket,
    :request_headers,
    :input,
    :output,
    :serve_task,
    output_offset: 0,
    decoded: "",
    raw: "",
    post_decoded: "",
    post_raw: ""
  ]

  def connect(:http, server_name, capabilities) do
    connect_http(:http, server_name, capabilities, true)
  end

  def connect(:http_json, server_name, capabilities) do
    connect_http(:http_json, server_name, capabilities, true)
  end

  def connect(:http_sse, server_name, capabilities) do
    connect_http(:http_sse, server_name, capabilities, false)
  end

  def connect(:stdio, server_name, capabilities) do
    {:ok, input} = Input.start_link([])
    {:ok, output} = StringIO.open("")
    connection_id = {:raw_peer, make_ref()}

    serve_task =
      Task.async(fn ->
        Stdio.serve(server_name, Input.stream(input), output, connection_id: connection_id)
      end)

    peer = %__MODULE__{
      transport: :stdio,
      server_name: to_string(server_name),
      session_id: StdioAdapter.connection_session_id(connection_id),
      input: input,
      output: output,
      serve_task: serve_task
    }

    :ok =
      push_stdio(
        peer,
        ProtocolTest.jsonrpc_request(
          1,
          "initialize",
          ProtocolTest.initialize_params(%{"capabilities" => capabilities})
        )
      )

    {:ok, %{"id" => 1, "result" => _result}, peer} = recv(peer, 2_000)
    :ok = push_stdio(peer, ProtocolTest.jsonrpc_notification("notifications/initialized"))
    :ok = await_initialized(peer.server_name, peer.session_id, 2_000)
    peer
  end

  def connect(:http_protected, server_name, capabilities, opts) when is_list(opts) do
    connect_http(
      :http_protected,
      server_name,
      capabilities,
      true,
      Keyword.get(opts, :headers, [])
    )
  end

  defp connect_http(transport, server_name, capabilities, json_response?, request_headers \\ []) do
    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {HTTPApp,
           server_name: server_name,
           allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"],
           json_response: json_response?},
        scheme: :http,
        port: 0,
        thousand_island_options: [num_acceptors: 1, shutdown_timeout: 100]
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    initialize =
      ProtocolTest.jsonrpc_request(
        1,
        "initialize",
        ProtocolTest.initialize_params(%{"capabilities" => capabilities})
      )

    response = http_post(port, initialize, nil, request_headers)
    200 = response.status
    session_id = Map.fetch!(response.headers, "mcp-session-id")

    %{status: 202} =
      http_post(
        port,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id,
        request_headers
      )

    {socket, decoded, raw} =
      if json_response? do
        {:ok, socket, stream_response, decoded, raw} =
          open_http_stream(port, session_id, request_headers)

        200 = stream_response.status
        {socket, decoded, raw}
      else
        {nil, "", ""}
      end

    %__MODULE__{
      transport: transport,
      server_name: to_string(server_name),
      session_id: session_id,
      bandit: bandit,
      port: port,
      socket: socket,
      request_headers: request_headers,
      decoded: decoded,
      raw: raw
    }
  end

  def start_request(%__MODULE__{transport: transport} = peer, id, method, params)
      when transport in [:http, :http_json, :http_protected] do
    payload = ProtocolTest.jsonrpc_request(id, method, params)

    pending =
      Task.async(fn ->
        http_post(peer.port, payload, peer.session_id, peer.request_headers)
      end)

    {pending, peer}
  end

  def start_request(%__MODULE__{transport: :http_sse} = peer, id, method, params) do
    payload = ProtocolTest.jsonrpc_request(id, method, params)

    {:ok, socket, response, decoded, raw} =
      open_http_post_stream(peer.port, payload, peer.session_id, peer.request_headers)

    if response.status != 200 do
      raise "expected POST SSE response, got #{response.status}: #{inspect({decoded, raw})}"
    end

    {{:http_sse, id},
     %{
       peer
       | post_socket: socket,
         post_decoded: decoded,
         post_raw: raw
     }}
  end

  def start_request(%__MODULE__{transport: :stdio} = peer, id, method, params) do
    :ok = push_stdio(peer, ProtocolTest.jsonrpc_request(id, method, params))
    {{:stdio, id}, peer}
  end

  def await_response(peer, pending, timeout_ms \\ 2_000)

  def await_response(%__MODULE__{transport: transport} = peer, pending, timeout_ms)
      when transport in [:http, :http_json, :http_protected] do
    response = Task.await(pending, timeout_ms)

    envelope =
      case response.body do
        "" -> nil
        body -> JSON.decode!(body)
      end

    {:ok, response.status, envelope, peer}
  end

  def await_response(
        %__MODULE__{transport: :http_sse} = peer,
        {:http_sse, request_id},
        timeout_ms
      ) do
    case recv_until(peer, &(&1["id"] == request_id), timeout_ms) do
      {:ok, envelope, peer} ->
        if is_port(peer.post_socket), do: :gen_tcp.close(peer.post_socket)

        {:ok, 200, envelope, %{peer | post_socket: nil, post_decoded: "", post_raw: ""}}

      {:error, reason, peer} ->
        {:error, reason, peer}
    end
  end

  def await_response(
        %__MODULE__{transport: :stdio} = peer,
        {:stdio, request_id},
        timeout_ms
      ) do
    recv_until(peer, &(&1["id"] == request_id), timeout_ms)
    |> case do
      {:ok, envelope, peer} -> {:ok, 200, envelope, peer}
      {:error, reason, peer} -> {:error, reason, peer}
    end
  end

  def post(%__MODULE__{transport: transport} = peer, envelope)
      when transport in [:http, :http_json, :http_sse, :http_protected] do
    response = http_post(peer.port, envelope, peer.session_id, peer.request_headers)
    {:ok, response.status, response.body, peer}
  end

  def post(%__MODULE__{transport: :stdio} = peer, envelope) do
    :ok = push_stdio(peer, envelope)
    {:ok, 202, "", peer}
  end

  def respond(peer, request_id, result) do
    post(peer, %{"jsonrpc" => "2.0", "id" => request_id, "result" => result})
  end

  def notify(peer, method, params \\ %{}) do
    post(peer, ProtocolTest.jsonrpc_notification(method, params))
  end

  def recv(%__MODULE__{transport: transport} = peer, timeout_ms)
      when transport in [:http, :http_json, :http_protected] do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_http_event(peer, deadline)
  end

  def recv(%__MODULE__{transport: :http_sse} = peer, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_http_post_event(peer, deadline)
  end

  def recv(%__MODULE__{transport: :stdio} = peer, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_stdio_line(peer, deadline)
  end

  def recv_until(peer, matcher, timeout_ms) when is_function(matcher, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_recv_until(peer, matcher, deadline)
  end

  def close(%__MODULE__{transport: transport} = peer)
      when transport in [:http, :http_json, :http_sse, :http_protected] do
    if is_port(peer.socket), do: :gen_tcp.close(peer.socket)
    if is_port(peer.post_socket), do: :gen_tcp.close(peer.post_socket)

    if is_pid(peer.bandit) and Process.alive?(peer.bandit) do
      GenServer.stop(peer.bandit)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def close(%__MODULE__{transport: :stdio} = peer) do
    if is_pid(peer.input) and Process.alive?(peer.input), do: Input.eof(peer.input)

    if match?(%Task{pid: pid} when is_pid(pid), peer.serve_task) and
         Process.alive?(peer.serve_task.pid) do
      monitor = Process.monitor(peer.serve_task.pid)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        2_000 ->
          Process.demonitor(monitor, [:flush])
          Process.exit(peer.serve_task.pid, :shutdown)
      end
    end

    if is_pid(peer.output) and Process.alive?(peer.output), do: StringIO.close(peer.output)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp do_recv_until(peer, matcher, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout, peer}
    else
      case recv(peer, remaining) do
        {:ok, envelope, peer} ->
          if matcher.(envelope) do
            {:ok, envelope, peer}
          else
            do_recv_until(peer, matcher, deadline)
          end

        {:error, reason, peer} ->
          {:error, reason, peer}
      end
    end
  end

  defp await_initialized(server_name, session_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_initialized(server_name, session_id, deadline)
  end

  defp do_await_initialized(server_name, session_id, deadline) do
    case Session.lifecycle(server_name, session_id) do
      {:ok, %{state: :initialized}} ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          do_await_initialized(server_name, session_id, deadline)
        end
    end
  end

  defp recv_http_event(peer, deadline) do
    case take_sse_event(peer.decoded) do
      {:ok, envelope, remaining} ->
        {:ok, envelope, %{peer | decoded: remaining}}

      :more ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout, peer}
        else
          case :gen_tcp.recv(peer.socket, 0, remaining_ms) do
            {:ok, chunk} ->
              {decoded, raw} = decode_available_chunked_body(peer.raw <> chunk, peer.decoded)
              recv_http_event(%{peer | decoded: decoded, raw: raw}, deadline)

            {:error, reason} ->
              {:error, reason, peer}
          end
        end
    end
  end

  defp recv_http_post_event(peer, deadline) do
    case take_sse_event(peer.post_decoded) do
      {:ok, envelope, remaining} ->
        {:ok, envelope, %{peer | post_decoded: remaining}}

      :more ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout, peer}
        else
          case :gen_tcp.recv(peer.post_socket, 0, remaining_ms) do
            {:ok, chunk} ->
              {decoded, raw} =
                decode_available_chunked_body(peer.post_raw <> chunk, peer.post_decoded)

              recv_http_post_event(%{peer | post_decoded: decoded, post_raw: raw}, deadline)

            {:error, reason} ->
              {:error, reason, peer}
          end
        end
    end
  end

  defp take_sse_event(decoded) do
    case String.split(decoded, "\n\n", parts: 2) do
      [event, remaining] ->
        data =
          event
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map_join(
            "\n",
            &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading())
          )

        if data == "" do
          take_sse_event(remaining)
        else
          {:ok, JSON.decode!(data), remaining}
        end

      [_incomplete] ->
        :more
    end
  end

  defp recv_stdio_line(peer, deadline) do
    {_input, output} = StringIO.contents(peer.output)
    available = binary_part(output, peer.output_offset, byte_size(output) - peer.output_offset)

    case String.split(available, "\n", parts: 2) do
      [line, _remaining] when line != "" ->
        offset = peer.output_offset + byte_size(line) + 1
        {:ok, JSON.decode!(line), %{peer | output_offset: offset}}

      _other ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout, peer}
        else
          receive do
          after
            min(5, remaining_ms) -> recv_stdio_line(peer, deadline)
          end
        end
    end
  end

  defp push_stdio(peer, envelope) do
    Input.push(peer.input, JSON.encode!(envelope) <> "\n")
  end

  defp open_http_stream(port, session_id, request_headers) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      [
        "GET /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Accept: text/event-stream\r\n",
        encode_request_headers(request_headers),
        session_headers(session_id),
        "Connection: keep-alive\r\n\r\n"
      ]
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, request)
    {:ok, head, rest} = recv_http_head(socket, "", 2_000)
    response = parse_http_head(head)
    {decoded, raw} = decode_available_chunked_body(rest, "")
    {:ok, socket, response, decoded, raw}
  end

  defp open_http_post_stream(port, payload, session_id, request_headers) do
    body = JSON.encode!(payload)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      [
        "POST /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Content-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\n",
        encode_request_headers(request_headers),
        session_headers(session_id),
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, request)
    {:ok, head, rest} = recv_http_head(socket, "", 2_000)
    response = parse_http_head(head)
    {decoded, raw} = decode_available_chunked_body(rest, "")
    {:ok, socket, response, decoded, raw}
  end

  defp http_post(port, payload, session_id, request_headers) do
    body = JSON.encode!(payload)

    request =
      [
        "POST /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Content-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\n",
        encode_request_headers(request_headers),
        session_headers(session_id),
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    :ok = :gen_tcp.send(socket, request)
    {:ok, raw_response} = recv_all(socket, "", 5_000)
    :ok = :gen_tcp.close(socket)
    parse_http_response(raw_response)
  end

  defp session_headers(nil), do: []

  defp session_headers(session_id) do
    [
      "MCP-Session-Id: ",
      session_id,
      "\r\nMCP-Protocol-Version: ",
      ProtocolTest.protocol_version(),
      "\r\n"
    ]
  end

  defp encode_request_headers(headers) when is_map(headers),
    do: encode_request_headers(Map.to_list(headers))

  defp encode_request_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} ->
      [to_string(name), ": ", to_string(value), "\r\n"]
    end)
  end

  defp recv_all(socket, acc, timeout_ms) do
    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk, timeout_ms)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_http_head(socket, acc, timeout_ms) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {:ok, head, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, timeout_ms) do
          {:ok, chunk} -> recv_http_head(socket, acc <> chunk, timeout_ms)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_http_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    parsed = parse_http_head(head)
    %{parsed | body: maybe_decode_http_body(parsed.headers, body)}
  end

  defp parse_http_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers, body: ""}
  end

  defp maybe_decode_http_body(headers, body) do
    if Map.get(headers, "transfer-encoding") == "chunked" do
      decode_complete_chunked_body(body, "")
    else
      body
    end
  end

  defp decode_complete_chunked_body("0\r\n\r\n", acc), do: acc

  defp decode_complete_chunked_body(body, acc) do
    [size_hex, rest] = String.split(body, "\r\n", parts: 2)
    {size, ""} = Integer.parse(size_hex, 16)
    <<chunk::binary-size(^size), "\r\n", remainder::binary>> = rest
    decode_complete_chunked_body(remainder, acc <> chunk)
  end

  defp decode_available_chunked_body("", acc), do: {acc, ""}

  defp decode_available_chunked_body(body, acc) do
    case String.split(body, "\r\n", parts: 2) do
      [size_hex, rest] ->
        case Integer.parse(size_hex, 16) do
          {0, ""} ->
            {acc, ""}

          {size, ""} when byte_size(rest) >= size + 2 ->
            <<chunk::binary-size(^size), "\r\n", remainder::binary>> = rest
            decode_available_chunked_body(remainder, acc <> chunk)

          _other ->
            {acc, body}
        end

      [_incomplete] ->
        {acc, body}
    end
  end

  defmodule Input do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    def stream(pid) do
      Stream.resource(
        fn -> pid end,
        fn pid ->
          case GenServer.call(pid, :next, :infinity) do
            {:line, line} -> {[line], pid}
            :eof -> {:halt, pid}
          end
        end,
        fn _pid -> :ok end
      )
    end

    def push(pid, line), do: GenServer.call(pid, {:push, line})
    def eof(pid), do: GenServer.call(pid, :eof)

    @impl true
    def init(:ok), do: {:ok, %{queue: :queue.new(), waiter: nil, eof?: false}}

    @impl true
    def handle_call({:push, _line}, _from, %{eof?: true} = state),
      do: {:reply, {:error, :closed}, state}

    def handle_call({:push, line}, _from, %{waiter: waiter} = state) when not is_nil(waiter) do
      GenServer.reply(waiter, {:line, line})
      {:reply, :ok, %{state | waiter: nil}}
    end

    def handle_call({:push, line}, _from, state) do
      {:reply, :ok, %{state | queue: :queue.in(line, state.queue)}}
    end

    def handle_call(:next, _from, %{eof?: true, queue: queue} = state) do
      case :queue.out(queue) do
        {{:value, line}, queue} -> {:reply, {:line, line}, %{state | queue: queue}}
        {:empty, _queue} -> {:reply, :eof, state}
      end
    end

    def handle_call(:next, from, state) do
      case :queue.out(state.queue) do
        {{:value, line}, queue} -> {:reply, {:line, line}, %{state | queue: queue}}
        {:empty, _queue} -> {:noreply, %{state | waiter: from}}
      end
    end

    def handle_call(:eof, _from, %{waiter: waiter} = state) when not is_nil(waiter) do
      GenServer.reply(waiter, :eof)
      {:reply, :ok, %{state | waiter: nil, eof?: true}}
    end

    def handle_call(:eof, _from, state), do: {:reply, :ok, %{state | eof?: true}}
  end
end
