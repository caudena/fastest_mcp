defmodule FastestMCP.ClientGroup.Coordinator do
  @moduledoc false
  use GenServer
  alias FastestMCP.{Client, Error}
  alias FastestMCP.ClientGroup.Members

  def start_link({_supervisor, opts} = args),
    do: GenServer.start_link(__MODULE__, args, Keyword.take(opts, [:name]))

  @impl true
  def init({supervisor, opts}) do
    {:ok,
     %{
       supervisor: supervisor,
       configs: opts[:clients],
       concurrency: opts[:max_concurrency],
       members: %{},
       monitors: %{},
       routes: %{},
       loaded?: false,
       load: nil,
       startup_error: nil
     }, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    children = Supervisor.which_children(state.supervisor)

    state =
      Map.merge(state, %{
        tasks: child_pid(children, Task.Supervisor),
        member_supervisor: child_pid(children, Members)
      })

    case capture(fn -> resolve_members(state, true) end) do
      {:ok, members} -> {:noreply, install_members(state, members)}
      {:error, error} -> {:noreply, %{state | startup_error: error}}
    end
  end

  @impl true
  def handle_call(:members, _, %{startup_error: error} = state) when not is_nil(error),
    do: {:reply, {:error, error}, state}

  def handle_call(:members, _, state), do: {:reply, {:ok, state.members}, state}

  def handle_call({:validated_route, name, previous, updated}, _, state) do
    routes =
      if Map.get(state.routes, name) == previous,
        do: Map.put(state.routes, name, updated),
        else: state.routes

    {:reply, {:ok, updated}, %{state | routes: routes}}
  end

  def handle_call({:refresh, opts}, from, state), do: refresh(state, from, :list, opts, true)

  def handle_call({:route, name, opts}, from, state) do
    case Map.fetch(state.routes, name) do
      {:ok, route} -> {:reply, {:ok, route}, state}
      :error when state.loaded? -> {:reply, {:error, unknown_tool(name)}, state}
      :error -> refresh(state, from, {:route, name}, Keyword.put(opts, :cache, :use), false)
    end
  end

  defp refresh(%{load: load} = state, from, request, opts, explicit?) when not is_nil(load) do
    waiter = {from, request, Process.monitor(elem(from, 0))}

    followup =
      if (explicit? and not load.explicit?) or cache_strength(opts) > cache_strength(load.opts) do
        case load.followup do
          {current, current_explicit?} ->
            {if(cache_strength(opts) > cache_strength(current), do: opts, else: current),
             explicit? or current_explicit?}

          nil ->
            {opts, explicit?}
        end
      else
        load.followup
      end

    {:noreply, %{state | load: %{load | waiters: [waiter | load.waiters], followup: followup}}}
  end

  defp refresh(state, from, request, opts, explicit?) do
    waiter = {from, request, Process.monitor(elem(from, 0))}
    launch_refresh(state, [waiter], opts, explicit?)
  end

  defp launch_refresh(state, waiters, opts, explicit?) do
    case capture(fn -> resolve_members(state, explicit?) end) do
      {:ok, members} ->
        deadline = FastestMCP.Deadline.from_options(opts, 10_000)

        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            capture(fn ->
              load_catalog(members, state.tasks, state.concurrency, opts, deadline)
            end)
          end)

        {:noreply,
         %{
           state
           | load: %{
               task: task,
               waiters: waiters,
               members: members,
               opts: opts,
               explicit?: explicit?,
               followup: nil
             }
         }}

      {:error, error} ->
        reply_error(waiters, error)
        {:noreply, %{state | load: nil}}
    end
  end

  @impl true
  def handle_info(
        {ref, _result},
        %{load: %{task: %{ref: ref}, followup: {opts, explicit?}} = load} = state
      ) do
    Process.demonitor(ref, [:flush])
    launch_refresh(%{state | load: nil}, load.waiters, opts, explicit?)
  end

  def handle_info({ref, result}, %{load: %{task: %{ref: ref}} = load} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, %{routes: routes, tools: tools}} ->
          Enum.each(load.waiters, fn {from, request, monitor} ->
            Process.demonitor(monitor, [:flush])

            reply =
              case request do
                :list ->
                  {:ok, tools}

                {:route, name} ->
                  case Map.fetch(routes, name) do
                    {:ok, route} -> {:ok, route}
                    :error -> {:error, unknown_tool(name)}
                  end
              end

            GenServer.reply(from, reply)
          end)

          state
          |> install_members(load.members)
          |> Map.merge(%{routes: routes, loaded?: true, startup_error: nil})

        {:error, error} ->
          reply_error(load.waiters, error)
          state
      end

    {:noreply, %{state | load: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{load: %{task: %{ref: ref}} = load} = state) do
    reply_error(load.waiters, %Error{
      code: :internal_error,
      message: "client group catalog worker failed",
      details: %{reason: inspect(reason)}
    })

    {:noreply, %{state | load: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state =
      if state.load do
        waiters = Enum.reject(state.load.waiters, fn {_, _, monitor} -> monitor == ref end)

        if waiters == [] do
          Task.shutdown(state.load.task, :brutal_kill)
          %{state | load: nil}
        else
          put_in(state.load.waiters, waiters)
        end
      else
        state
      end

    # Routes stay bound to the old pid. Healthy members remain available; an
    # explicit refresh is the only way to bind replacement member processes.
    {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{load: nil}), do: :ok
  def terminate(_, state), do: Task.shutdown(state.load.task, :brutal_kill)

  defp load_catalog(members, supervisor, concurrency, opts, deadline) do
    snapshots =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        Enum.sort(members),
        fn {name, client} ->
          capture(fn ->
            remaining = deadline - System.monotonic_time(:millisecond)

            if remaining <= 0,
              do: raise(Error, code: :timeout, message: "client group catalog timed out")

            {name, Client.catalog_snapshot!(client, Keyword.put(opts, :timeout_ms, remaining))}
          end)
        end,
        max_concurrency: concurrency,
        timeout: max(deadline - System.monotonic_time(:millisecond), 1),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {:ok, snapshot}} ->
          snapshot

        {:ok, {:error, error}} ->
          raise error

        {:exit, :timeout} ->
          raise Error, code: :timeout, message: "client group catalog timed out"

        {:exit, reason} ->
          raise Error,
            code: :internal_error,
            message: "client group member catalog failed",
            details: %{reason: inspect(reason)}
      end)

    {routes, tools} =
      Enum.reduce(snapshots, {%{}, []}, fn {alias_name, snapshot}, acc ->
        revision = Client.catalog_revision!(snapshot.client)

        unless revision.ready? and revision.generation == snapshot.generation do
          raise Error,
            code: :invalid_request,
            message: "client catalog changed during group discovery; refresh again"
        end

        Enum.reduce(snapshot.tools, acc, fn tool, {routes, tools} ->
          name = alias_name <> "_" <> tool["name"]

          route = %{
            server_name: alias_name,
            upstream_name: tool["name"],
            client: snapshot.client,
            generation: snapshot.generation
          }

          case Map.get(routes, name) do
            nil ->
              :ok

            ^route ->
              :ok

            _different_member ->
              raise Error,
                code: :invalid_request,
                message: "client group tool name collision: #{inspect(name)}"
          end

          {Map.put(routes, name, route), [Map.put(tool, "name", name) | tools]}
        end)
      end)

    %{routes: routes, tools: Enum.reverse(tools)}
  end

  defp resolve_members(state, explicit?) do
    children = Supervisor.which_children(state.member_supervisor)

    Map.new(state.configs, fn
      {name, {:existing, ref}} ->
        client =
          if explicit? or not Map.has_key?(state.members, name),
            do: Client.pin!(ref),
            else: Client.pin!(state.members[name])

        {name, client}

      {name, _opts} ->
        pid = child_pid(children, {:client, name})

        unless is_pid(pid),
          do:
            raise(Error,
              code: :not_found,
              message: "client group member #{inspect(name)} is unavailable"
            )

        {name, Client.pin!(pid)}
    end)
  end

  defp install_members(state, members) do
    Enum.each(state.monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    monitors = Map.new(members, fn {name, client} -> {Process.monitor(client.pid), name} end)
    %{state | members: members, monitors: monitors}
  end

  defp child_pid(children, id),
    do:
      Enum.find_value(children, fn
        {^id, pid, _, _} when is_pid(pid) -> pid
        _ -> nil
      end)

  defp unknown_tool(name),
    do: %Error{
      code: :method_not_found,
      message: "unknown group tool #{inspect(name)}; refresh list_tools after catalog changes"
    }

  defp cache_strength(opts) do
    case Keyword.get(opts, :cache, :use) do
      :use -> 0
      :refresh -> 1
      :bypass -> 2
      _ -> 0
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, _ ->
      {:error, %Error{code: :internal_error, message: "client group member is unavailable"}}
  end

  defp reply_error(waiters, error) do
    Enum.each(waiters, fn {from, _, monitor} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, {:error, error})
    end)
  end
end
