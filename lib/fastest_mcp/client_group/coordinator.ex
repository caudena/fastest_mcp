defmodule FastestMCP.ClientGroup.Coordinator do
  @moduledoc false
  # Pins a group's members and owns its routing catalog. A catalog load runs
  # in a task; refresh callers join the running load, and a caller asking for
  # a stronger refresh than the running load gets one follow-up load.
  use GenServer
  alias FastestMCP.{Deadline, Error}
  alias FastestMCP.Client.{Catalog, Connection}
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

    case resolve_members(state, true) do
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
    case resolve_members(state, explicit?) do
      {:ok, members} ->
        deadline = Deadline.from_options(opts, 10_000)

        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            load_catalog(members, state.tasks, state.concurrency, opts, deadline)
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
            GenServer.reply(from, reply(request, routes, tools))
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
    reply_error(
      load.waiters,
      Error.internal("client group catalog worker failed", %{reason: inspect(reason)})
    )

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

  defp reply(:list, _routes, tools), do: {:ok, tools}

  defp reply({:route, name}, routes, _tools),
    do: with(:error <- Map.fetch(routes, name), do: {:error, unknown_tool(name)})

  ## Catalog loads

  defp load_catalog(members, supervisor, concurrency, opts, deadline) do
    with {:ok, timeout} <- Deadline.check(deadline, "client group catalog"),
         {:ok, snapshots} <- snapshots(members, supervisor, concurrency, opts, deadline, timeout),
         :ok <- check_generations(snapshots),
         do: routes(snapshots)
  end

  # Member snapshots in alias order, or the first failure.
  defp snapshots(members, supervisor, concurrency, opts, deadline, timeout) do
    supervisor
    |> Task.Supervisor.async_stream_nolink(
      Enum.sort(members),
      &snapshot(&1, opts, deadline),
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, snapshot}}, {:ok, snapshots} ->
        {:cont, {:ok, [snapshot | snapshots]}}

      {:ok, error}, _snapshots ->
        {:halt, error}

      {:exit, :timeout}, _snapshots ->
        {:halt, {:error, Error.timeout("client group catalog")}}

      {:exit, reason}, _snapshots ->
        {:halt,
         {:error,
          Error.internal("client group member catalog failed", %{reason: inspect(reason)})}}
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp snapshot({name, client}, opts, deadline) do
    with {:ok, remaining} <- Deadline.check(deadline, "client group catalog"),
         {:ok, snapshot} <-
           Catalog.snapshot(client, Keyword.put(opts, :timeout_ms, remaining)),
         do: {:ok, {name, snapshot}}
  end

  # A member whose catalog changed while the group loaded fails the load.
  defp check_generations(snapshots) do
    Enum.find_value(snapshots, :ok, fn {_name, snapshot} ->
      case Catalog.revision(snapshot.client) do
        {:ok, %{ready?: true, generation: generation}} when generation == snapshot.generation ->
          nil

        {:ok, _changed} ->
          {:error,
           %Error{
             code: :invalid_request,
             message: "client catalog changed during group discovery; refresh again"
           }}

        error ->
          error
      end
    end)
  end

  # Versions of one member tool share a route; two routes under one public
  # name are a collision.
  defp routes(snapshots) do
    entries =
      for {alias_name, snapshot} <- snapshots, tool <- snapshot.tools do
        name = alias_name <> "_" <> tool["name"]

        route = %{
          server_name: alias_name,
          upstream_name: tool["name"],
          client: snapshot.client,
          generation: snapshot.generation
        }

        {{name, route}, Map.put(tool, "name", name)}
      end

    routes = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    case routes -- Enum.uniq_by(routes, &elem(&1, 0)) do
      [] ->
        {:ok, %{routes: Map.new(routes), tools: Enum.map(entries, &elem(&1, 1))}}

      [{name, _route} | _collisions] ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "client group tool name collision: #{inspect(name)}"
         }}
    end
  end

  ## Members

  defp resolve_members(state, explicit?) do
    children = Supervisor.which_children(state.member_supervisor)

    Enum.reduce_while(state.configs, {:ok, %{}}, fn {name, config}, {:ok, members} ->
      case pin(state, children, name, config, explicit?) do
        {:ok, client} -> {:cont, {:ok, Map.put(members, name, client)}}
        error -> {:halt, error}
      end
    end)
  end

  # A borrowed client is resolved by its reference again only on an explicit
  # refresh.
  defp pin(state, _children, name, {:existing, ref}, explicit?) do
    case state.members do
      %{^name => client} when not explicit? -> Connection.pin(client)
      _members -> Connection.pin(ref)
    end
  end

  defp pin(_state, children, name, _opts, _explicit?) do
    case child_pid(children, {:client, name}) do
      nil ->
        {:error,
         %Error{code: :not_found, message: "client group member #{inspect(name)} is unavailable"}}

      pid ->
        Connection.pin(pid)
    end
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

  defp reply_error(waiters, error) do
    Enum.each(waiters, fn {from, _, monitor} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, {:error, error})
    end)
  end
end
