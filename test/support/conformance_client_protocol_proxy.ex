defmodule FastestMCP.TestSupport.ConformanceClientProtocolProxy do
  @moduledoc false

  @runner_protocol_fragment ~s("protocolVersion":"2025-03-26")
  @current_protocol_fragment ~s("protocolVersion":"2025-11-25")
  @initialize_method_fragment ~s("method":"initialize")
  @jsonrpc_method_fragment ~s("method":)
  @max_initialize_response_bytes 65_536

  def start!(upstream_url) when is_binary(upstream_url) do
    uri = URI.parse(upstream_url)

    unless uri.scheme == "http" and loopback?(uri.host) do
      raise ArgumentError,
            "conformance client protocol proxy requires a loopback HTTP URL, got: #{inspect(upstream_url)}"
    end

    upstream_port = uri.port || 80

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, proxy_port}} = :inet.sockname(listener)

    acceptor =
      spawn(fn ->
        accept_loop(listener, uri.host, upstream_port)
      end)

    %{
      listener: listener,
      acceptor: acceptor,
      url: proxy_url(uri, proxy_port)
    }
  end

  def stop(%{listener: listener, acceptor: acceptor}) do
    :gen_tcp.close(listener)

    if Process.alive?(acceptor) do
      Process.exit(acceptor, :shutdown)
    end

    :ok
  end

  @doc false
  def rewrite_chunk(:passthrough, data) when is_binary(data), do: {data, :passthrough}

  def rewrite_chunk({:awaiting_request, _buffer}, data) when is_binary(data),
    do: {data, :passthrough}

  def rewrite_chunk({:awaiting_initialize, buffer}, data)
      when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data

    cond do
      :binary.match(combined, @runner_protocol_fragment) != :nomatch ->
        {
          String.replace(combined, @runner_protocol_fragment, @current_protocol_fragment,
            global: false
          ),
          :passthrough
        }

      :binary.match(combined, @current_protocol_fragment) != :nomatch ->
        {combined, :passthrough}

      byte_size(combined) >= @max_initialize_response_bytes ->
        {combined, :passthrough}

      true ->
        {"", {:awaiting_initialize, combined}}
    end
  end

  @doc false
  def classify_request(:passthrough, _data), do: :passthrough

  def classify_request({:awaiting_initialize, _buffer} = state, _data), do: state

  def classify_request({:awaiting_request, buffer}, data)
      when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data

    cond do
      :binary.match(combined, @initialize_method_fragment) != :nomatch ->
        {:awaiting_initialize, ""}

      :binary.match(combined, @jsonrpc_method_fragment) != :nomatch ->
        :passthrough

      String.starts_with?(combined, "GET ") ->
        :passthrough

      byte_size(combined) >= @max_initialize_response_bytes ->
        :passthrough

      true ->
        {:awaiting_request, combined}
    end
  end

  defp accept_loop(listener, upstream_host, upstream_port) do
    case :gen_tcp.accept(listener) do
      {:ok, downstream} ->
        hand_off_connection(downstream, upstream_host, upstream_port)
        accept_loop(listener, upstream_host, upstream_port)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp hand_off_connection(downstream, upstream_host, upstream_port) do
    bridge =
      spawn(fn ->
        receive do
          {:accepted, ^downstream} -> bridge(downstream, upstream_host, upstream_port)
        end
      end)

    case :gen_tcp.controlling_process(downstream, bridge) do
      :ok ->
        send(bridge, {:accepted, downstream})

      {:error, _reason} ->
        :gen_tcp.close(downstream)
        Process.exit(bridge, :kill)
    end
  end

  defp bridge(downstream, upstream_host, upstream_port) do
    case :gen_tcp.connect(
           String.to_charlist(upstream_host),
           upstream_port,
           [:binary, packet: :raw, active: false],
           5_000
         ) do
      {:ok, upstream} ->
        :ok = :inet.setopts(downstream, active: :once)
        :ok = :inet.setopts(upstream, active: :once)

        relay(downstream, upstream, {:awaiting_request, ""})

      {:error, _reason} ->
        :gen_tcp.close(downstream)
    end
  end

  defp relay(downstream, upstream, rewrite_state) do
    receive do
      {:tcp, ^downstream, data} ->
        rewrite_state = classify_request(rewrite_state, data)

        case :gen_tcp.send(upstream, data) do
          :ok ->
            :ok = :inet.setopts(downstream, active: :once)
            relay(downstream, upstream, rewrite_state)

          {:error, _reason} ->
            close_pair(downstream, upstream)
        end

      {:tcp, ^upstream, data} ->
        {rewritten, rewrite_state} = rewrite_chunk(rewrite_state, data)

        with :ok <- send_if_present(downstream, rewritten),
             :ok <- :inet.setopts(upstream, active: :once) do
          relay(downstream, upstream, rewrite_state)
        else
          {:error, _reason} -> close_pair(downstream, upstream)
        end

      {:tcp_closed, ^upstream} ->
        flush_pending(downstream, rewrite_state)
        close_pair(downstream, upstream)

      {:tcp_closed, ^downstream} ->
        close_pair(downstream, upstream)

      {:tcp_error, socket, _reason} when socket in [downstream, upstream] ->
        close_pair(downstream, upstream)
    end
  end

  defp send_if_present(_socket, ""), do: :ok
  defp send_if_present(socket, data), do: :gen_tcp.send(socket, data)

  defp flush_pending(downstream, {:awaiting_initialize, buffer}),
    do: send_if_present(downstream, buffer)

  defp flush_pending(_downstream, :passthrough), do: :ok

  defp close_pair(downstream, upstream) do
    :gen_tcp.close(downstream)
    :gen_tcp.close(upstream)
    :ok
  end

  defp proxy_url(uri, proxy_port) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if is_binary(uri.query), do: "?" <> uri.query, else: ""
    "http://127.0.0.1:#{proxy_port}#{path}#{query}"
  end

  defp loopback?(host) when is_binary(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp loopback?(_host), do: false
end
