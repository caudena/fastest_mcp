defmodule FastestMCP.ServerRuntime.Lifecycle do
  @moduledoc false
  # Owns what a running server needs besides its supervised processes: entered
  # lifespans, provider runtimes, the session state store, the runtime quota,
  # and the runtime's ETS tables, released in reverse on shutdown. It also starts the state of
  # stateful middleware under the runtime's middleware supervisor and keeps
  # the attached middleware in the materialized server.

  use GenServer

  alias FastestMCP.ComponentIndex
  alias FastestMCP.ComponentManager
  alias FastestMCP.Lifespan
  alias FastestMCP.Middleware
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer
  alias FastestMCP.Registry
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.TTLStore

  def start_link({server, config}) do
    GenServer.start_link(__MODULE__, {server, config},
      name: Registry.via({:lifecycle, to_string(server.name)})
    )
  end

  def info(server_name), do: GenServer.call(Registry.via({:lifecycle, server_name}), :info)

  @impl true
  def init({server, config}) do
    name = to_string(server.name)

    manager =
      ComponentManager.new(name, GenServer.whereis(Registry.via({:component_manager, name})))

    server = %{server | providers: server.providers ++ [Provider.new(manager)]}

    with {:ok, lifespan_context, cleanups} <-
           Lifespan.run_all(server, Server.runtime_lifespans(server)),
         {:ok, server} <- materialize(server, Registry.via({:middleware, name}), cleanups),
         {:ok, store} <- start_state_store(config.session_state_store, server, cleanups) do
      # Trap exits only once started: until then an exit signal from the
      # supervisor (e.g. an owner killing a stuck startup) must stop us.
      Process.flag(:trap_exit, true)
      terminated_sessions = TTLStore.new(config.terminated_session_ttl)
      schedule_sweep(config.terminated_session_ttl)

      {:ok,
       %{
         server: server,
         lifespan_cleanups: cleanups,
         info: %{
           server: server,
           config: config,
           component_manager: manager,
           lifespan_context: lifespan_context,
           session_state_store: store,
           terminated_session_store: terminated_sessions,
           runtime_quota:
             RuntimeQuota.new(
               pending_requests: config.max_runtime_pending_requests,
               active_requests: config.max_runtime_active_requests,
               sse_replay_bytes: config.sse_replay_max_total_bytes
             ),
           component_index: ComponentIndex.create(name, Server.all_components(server)),
           # Counts the changes of the tool, resource, and prompt lists; see
           # `FastestMCP.Notifications.list_changed/3`.
           component_generations: :atomics.new(3, signed: false),
           schema_cache:
             :ets.new(:fastest_mcp_schema_cache, [
               :set,
               :public,
               read_concurrency: true,
               write_concurrency: true
             ]),
           strict_request_ids: config.strict_request_ids,
           signing_secret: Config.signing_secret(config)
         }
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  @impl true
  def handle_info(:sweep, state) do
    TTLStore.sweep(state.info.terminated_session_store)
    schedule_sweep(state.info.terminated_session_store.ttl_ms)
    {:noreply, state}
  end

  # Processes that lifespans and providers link to stop the runtime when they
  # crash, but not when they finish normally, as a task does; the session
  # state store stops it either way. GenServer handles the parent's exit.
  def handle_info({:EXIT, pid, reason}, state) do
    if reason == :normal and pid != state.info.session_state_store.store,
      do: {:noreply, state},
      else: {:stop, {:linked_process_exit, pid, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    shutdown_providers(state.server)
    Lifespan.cleanup_all(state.lifespan_cleanups)
  end

  defp schedule_sweep(:infinity), do: :ok
  defp schedule_sweep(ttl_ms), do: Process.send_after(self(), :sweep, min(ttl_ms, 60_000))

  defp start_state_store({module, opts}, server, cleanups) do
    case guarded(fn -> module.start_link(opts) end) do
      {:ok, {:ok, store}} ->
        {:ok, %{module: module, store: store}}

      failure ->
        shutdown_providers(server)
        Lifespan.cleanup_all(cleanups)
        {:error, failure_reason(failure)}
    end
  end

  defp materialize(server, supervisor, cleanups) do
    with {:error, reason} <- materialize_server(server, supervisor) do
      Lifespan.cleanup_all(cleanups)
      {:error, reason}
    end
  end

  # Middleware state stops with its supervisor, also when startup fails.
  defp materialize_server(%Server{} = server, supervisor) do
    with {:ok, providers} <-
           start_all(
             server.providers,
             &materialize_provider(&1, supervisor),
             &shutdown_provider/1
           ) do
      case start_all(
             Server.runtime_middleware(server),
             &Middleware.start(&1, supervisor),
             fn _middleware -> :ok end
           ) do
        {:ok, middleware} ->
          {:ok, %{server | providers: providers, middleware: middleware}}

        {:error, reason} ->
          providers |> Enum.reverse() |> Enum.each(&guarded(fn -> shutdown_provider(&1) end))
          {:error, reason}
      end
    end
  end

  # Starts each item in order; on failure, stops the started ones in reverse.
  defp start_all(items, start, stop) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, started} ->
      case guarded(fn -> start.(item) end) do
        {:ok, {:ok, value}} ->
          {:cont, {:ok, [value | started]}}

        failure ->
          Enum.each(started, &guarded(fn -> stop.(&1) end))
          {:halt, {:error, failure_reason(failure)}}
      end
    end)
    |> case do
      {:ok, started} -> {:ok, Enum.reverse(started)}
      error -> error
    end
  end

  defp failure_reason({:ok, {:error, reason}}), do: reason
  defp failure_reason({:error, reason}), do: reason
  defp failure_reason({:ok, other}), do: {:invalid_start_result, other}

  defp materialize_provider(%Provider{inner: %MountedServer{} = mounted} = provider, supervisor) do
    with {:ok, lifespan_context, cleanups} <-
           Lifespan.run_all(mounted.server, mounted.server.lifespans) do
      case materialize_server(mounted.server, supervisor) do
        {:ok, server} ->
          {:ok,
           %{
             provider
             | inner: %{
                 mounted
                 | server: server,
                   lifespan_context: lifespan_context,
                   lifespan_cleanups: cleanups
               }
           }}

        {:error, reason} ->
          Lifespan.cleanup_all(cleanups)
          {:error, reason}
      end
    end
  end

  defp materialize_provider(%Provider{inner: %module{} = inner} = provider, _supervisor) do
    with {:ok, activated} <- module.activate_runtime(inner),
         do: {:ok, %{provider | inner: activated}}
  end

  defp shutdown_providers(%Server{} = server) do
    server.providers |> Enum.reverse() |> Enum.each(&guarded(fn -> shutdown_provider(&1) end))
  end

  defp shutdown_provider(%Provider{inner: %MountedServer{} = mounted}) do
    shutdown_providers(mounted.server)
    Lifespan.cleanup_all(mounted.lifespan_cleanups || [])
  end

  defp shutdown_provider(%Provider{inner: %module{} = inner}),
    do: module.deactivate_runtime(inner)

  # Provider and middleware runtimes run application code.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
