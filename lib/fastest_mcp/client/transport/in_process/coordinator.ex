defmodule FastestMCP.Client.Transport.InProcess.Coordinator do
  @moduledoc false

  use GenServer

  alias FastestMCP.Registry
  alias FastestMCP.Transport.Stdio

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send_envelope(coordinator, envelope),
    do: GenServer.call(coordinator, {:send_envelope, envelope})

  def close(coordinator), do: GenServer.call(coordinator, :close)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    coordinator = self()
    owner_monitor = Process.monitor(owner)
    server_name = Keyword.fetch!(opts, :server_name)
    connection_id = Keyword.fetch!(opts, :connection_id)
    auth_input = Keyword.get(opts, :auth_input, %{})
    {:ok, server_pid} = Registry.lookup_server(server_name)
    server_monitor = Process.monitor(server_pid)

    {serve_pid, serve_monitor} =
      spawn_monitor(fn ->
        Stdio.serve(server_name, input_stream(coordinator), coordinator,
          connection_id: connection_id,
          auth_input: auth_input
        )
      end)

    {:ok,
     %{
       owner: owner,
       owner_monitor: owner_monitor,
       server_pid: server_pid,
       server_monitor: server_monitor,
       serve_pid: serve_pid,
       serve_monitor: serve_monitor,
       input_queue: :queue.new(),
       input_waiter: nil,
       closing?: false
     }}
  end

  @impl true
  def handle_call({:send_envelope, envelope}, _from, %{closing?: false} = state) do
    line = JSON.encode!(envelope) <> "\n"

    case state.input_waiter do
      nil ->
        {:reply, :ok, %{state | input_queue: :queue.in(line, state.input_queue)}}

      waiter ->
        GenServer.reply(waiter, {:line, line})
        {:reply, :ok, %{state | input_waiter: nil}}
    end
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:send_envelope, _envelope}, _from, state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(:next_input, from, state) do
    case :queue.out(state.input_queue) do
      {{:value, line}, queue} ->
        {:reply, {:line, line}, %{state | input_queue: queue}}

      {:empty, _queue} when state.closing? ->
        {:reply, :eof, state}

      {:empty, _queue} ->
        {:noreply, %{state | input_waiter: from}}
    end
  end

  def handle_call(:close, _from, state) do
    state = close_input(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    case io_request_data(request) do
      {:ok, data} ->
        send(state.owner, {:fastest_mcp_transport_data, self(), data})
        send(from, {:io_reply, reply_as, :ok})

      {:error, reason} ->
        send(from, {:io_reply, reply_as, {:error, reason}})
    end

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner_monitor: monitor, owner: owner} = state
      ) do
    {:stop, :normal, close_input(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, server_pid, reason},
        %{server_monitor: monitor, server_pid: server_pid} = state
      ) do
    unless state.closing? do
      send(state.owner, {:fastest_mcp_transport_closed, self(), {:server_down, reason}})
    end

    {:stop, :normal, close_input(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, serve_pid, reason},
        %{serve_monitor: monitor, serve_pid: serve_pid} = state
      ) do
    unless state.closing? do
      send(state.owner, {:fastest_mcp_transport_closed, self(), reason})
    end

    {:stop, :normal, close_input(state)}
  end

  @impl true
  def terminate(reason, state) do
    unless state.closing? do
      send(state.owner, {:fastest_mcp_transport_closed, self(), reason})
    end

    state = close_input(state)

    if is_pid(state.serve_pid) and Process.alive?(state.serve_pid) do
      Process.exit(state.serve_pid, :shutdown)
    end

    :ok
  end

  defp input_stream(coordinator) do
    Stream.resource(
      fn -> coordinator end,
      fn coordinator ->
        case GenServer.call(coordinator, :next_input, :infinity) do
          {:line, line} -> {[line], coordinator}
          :eof -> {:halt, coordinator}
        end
      end,
      fn _coordinator -> :ok end
    )
  end

  defp close_input(%{input_waiter: nil} = state), do: %{state | closing?: true}

  defp close_input(%{input_waiter: waiter} = state) do
    GenServer.reply(waiter, :eof)
    %{state | input_waiter: nil, closing?: true}
  end

  defp io_request_data({:put_chars, _encoding, chars}),
    do: {:ok, IO.iodata_to_binary(chars)}

  defp io_request_data({:put_chars, chars}), do: {:ok, IO.iodata_to_binary(chars)}

  defp io_request_data({:put_chars, _encoding, module, function, args}) do
    {:ok, module |> apply(function, args) |> IO.iodata_to_binary()}
  rescue
    error -> {:error, error}
  end

  defp io_request_data({:requests, requests}) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, chunks} ->
      case io_request_data(request) do
        {:ok, chunk} -> {:cont, {:ok, [chunks, chunk]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, IO.iodata_to_binary(chunks)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp io_request_data(_request), do: {:error, :request}
end
