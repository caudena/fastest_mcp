defmodule FastestMCP.Transport.Stdio.OutputGuard do
  @moduledoc false
  # Keeps stdout for the stdio wire. A stdio connection writing to stdout holds
  # redirects here: stdout Logger handlers write to stderr instead, and so do
  # processes given the stderr group leader (the worker supervisors of a
  # running server). Each redirect is counted across holders and undone when
  # the last holder releases it; a holder that exits, even killed, releases
  # what it held.
  #
  # A holder may also name a server started on its behalf: that start blocks
  # in lifespans without noticing the holder exit, so the runtime is killed
  # when the holder exits before the runtime published itself.

  use GenServer

  alias FastestMCP.Registry

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # Holds `logger: true` and `group_leaders: pids` redirects, and the
  # `starting: server_name` start, for the calling process.
  def acquire(opts), do: GenServer.call(__MODULE__, {:acquire, opts})

  def release, do: GenServer.call(__MODULE__, :release)

  @impl true
  def init(:ok), do: {:ok, %{holders: %{}, redirects: %{}}}

  @impl true
  def handle_call({:acquire, opts}, {pid, _tag}, state) do
    holder =
      Map.get_lazy(state.holders, pid, fn ->
        %{monitor: Process.monitor(pid), redirects: [], starting: nil}
      end)

    holder = %{holder | starting: opts[:starting] || holder.starting}
    targets = if(opts[:logger], do: [:logger], else: []) ++ Keyword.get(opts, :group_leaders, [])
    {reply, holder, state} = Enum.reduce_while(targets, {:ok, holder, state}, &hold/2)
    {:reply, reply, put_in(state.holders[pid], holder)}
  end

  def handle_call(:release, {pid, _tag}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _holders} ->
        {:reply, :ok, state}

      {holder, holders} ->
        Process.demonitor(holder.monitor, [:flush])
        {:reply, :ok, release(holder, %{state | holders: holders})}
    end
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {holder, holders} = Map.pop!(state.holders, pid)
    abort_start(holder.starting)
    {:noreply, release(holder, %{state | holders: holders})}
  end

  # The first holder of a target redirects it, the last one restores it.
  defp hold(target, {:ok, holder, state} = acc) do
    with false <- target in holder.redirects,
         {:ok, entry} <- add_holder(state.redirects[target], target) do
      {:cont,
       {:ok, %{holder | redirects: [target | holder.redirects]},
        put_in(state.redirects[target], entry)}}
    else
      true -> {:cont, acc}
      {:error, reason} -> {:halt, {{:error, reason}, holder, state}}
    end
  end

  defp add_holder(nil, target),
    do: with({:ok, undo} <- redirect(target), do: {:ok, %{count: 1, undo: undo}})

  defp add_holder(entry, _target), do: {:ok, %{entry | count: entry.count + 1}}

  defp release(holder, state) do
    Enum.reduce(holder.redirects, state, fn target, state ->
      case state.redirects[target] do
        %{count: 1, undo: undo} ->
          restore(target, undo)
          %{state | redirects: Map.delete(state.redirects, target)}

        entry ->
          put_in(state.redirects[target], %{entry | count: entry.count - 1})
      end
    end)
  end

  # Standard handlers writing to stdout move to stderr. Any other handler
  # writing to stdout, or a non-standard default handler, cannot be moved, so
  # serving fails closed.
  defp redirect(:logger) do
    handlers = :logger.get_handler_config()

    case Enum.find(handlers, &unsupported_handler?/1) do
      nil -> handlers |> Enum.filter(&stdout_handler?/1) |> redirect_handlers([])
      %{id: id, module: module} -> {:error, {:unsupported_stdout_logger_handler, id, module}}
    end
  end

  defp redirect(pid) do
    {:group_leader, original} = Process.info(pid, :group_leader)
    Process.group_leader(pid, Process.whereis(:standard_error))
    {:ok, original}
  rescue
    _error -> {:error, {:cannot_redirect_group_leader, pid}}
  end

  defp restore(:logger, handlers), do: Enum.each(handlers, &put_handler/1)

  defp restore(pid, group_leader) do
    Process.group_leader(pid, group_leader)
  rescue
    # The process is gone.
    ArgumentError -> :ok
  end

  defp stdout_handler?(handler),
    do: match?(%{module: :logger_std_h, config: %{type: :standard_io}}, handler)

  defp unsupported_handler?(%{module: :logger_std_h}), do: false
  defp unsupported_handler?(%{id: :default}), do: true
  defp unsupported_handler?(handler), do: match?(%{config: %{type: :standard_io}}, handler)

  defp redirect_handlers([], redirected), do: {:ok, redirected}

  defp redirect_handlers([handler | rest], redirected) do
    case put_handler(put_in(handler.config.type, :standard_error)) do
      :ok ->
        redirect_handlers(rest, [handler | redirected])

      {:error, reason} ->
        Enum.each([handler | redirected], &put_handler/1)
        {:error, {:cannot_redirect_logger_handler, handler.id, reason}}
    end
  end

  # Replaces the handler with the id of `handler` by `handler`.
  defp put_handler(%{id: id, module: module} = handler) do
    _ = :logger.remove_handler(id)
    :logger.add_handler(id, module, Map.drop(handler, [:id, :module]))
  end

  defp abort_start(nil), do: :ok

  # Kills the server's supervisor and the one of its runtime, which traps exits
  # while it is blocked starting its children.
  defp abort_start(server_name) do
    if Registry.lookup_runtime(server_name) == {:error, :not_found} do
      for lookup <- [&Registry.lookup_server/1, &Registry.lookup_runtime_supervisor/1],
          {:ok, pid} <- [lookup.(server_name)],
          do: Process.exit(pid, :kill)
    end

    :ok
  end
end
