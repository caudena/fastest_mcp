defmodule FastestMCP.Session do
  @moduledoc false
  # Coordinates one legacy (`2025-11-25`) MCP session: its lifecycle, request
  # correlation in both directions, progress, output streams (`Session.Outbox`),
  # server notifications, peer tasks, URL elicitations, resource
  # subscriptions, and idle expiry. User-facing session values live in the
  # `FastestMCP.SessionStateStore`.

  use GenServer, restart: :transient
  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Elicitation.URL, as: URLElicitation
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.Middleware.RateLimiting.SlidingWindow
  alias FastestMCP.Notifications
  alias FastestMCP.Options
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.Redactor
  alias FastestMCP.Protocol.Sampling, as: ProtocolSampling
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Registry
  alias FastestMCP.Root
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.Session.Outbox
  alias FastestMCP.Session.Progress
  alias FastestMCP.SessionStateStore
  alias FastestMCP.SSEReplay

  require Logger

  @termination_timeout 5_000
  @request_timeout_ms 60_000
  @replay_options %{
    sse_replay_max_events: :max_events,
    sse_replay_max_stream_bytes: :max_stream_bytes,
    sse_replay_max_total_bytes: :max_total_bytes,
    sse_replay_ttl_ms: :ttl_ms
  }

  # Field defaults are the session defaults; `ServerRuntime.Config` validates
  # the runtime options that override them.
  defstruct [
    :server_name,
    :session_id,
    :session_state_store,
    :runtime_quota,
    :task_supervisor,
    :protocol_version,
    :client_capabilities,
    :server_capabilities,
    :client_info,
    :roots,
    :replay,
    :log_rate,
    :peer_progress_rate,
    event_bus: %EventBus{},
    idle_ttl_ms: :infinity,
    max_request_ids: 100_000,
    max_pending_requests: 128,
    max_active_requests: 128,
    max_peer_tasks: 128,
    max_peer_task_callbacks: 128,
    max_queued_messages: 1_024,
    max_queued_bytes: 16 * 1_024 * 1_024,
    request_timeout_ms: @request_timeout_ms,
    max_progress_per_second: 20,
    max_inbound_progress_per_second: 100,
    max_logs_per_second: 100,
    redaction_opts: [],
    lifecycle_state: :new,
    auth_identity: :unbound,
    logging_level: "info",
    client_request_ids: MapSet.new(),
    server_request_ids: MapSet.new(),
    resource_subscriptions: MapSet.new(),
    sinks: %{},
    sink_monitors: %{},
    stream_owners: %{},
    queued_messages: :queue.new(),
    queued_bytes: 0,
    pending_requests: %{},
    pending_monitors: %{},
    active_requests: %{},
    active_monitors: %{},
    receiver_tasks: %{},
    receiver_task_requests: %{},
    progress_tokens: %{},
    peer_progress_tokens: %{},
    peer_tasks: %{},
    peer_task_callbacks: %{},
    peer_task_callback_monitors: %{},
    url_elicitations: %{}
  ]

  def start_link(opts, {server_name, session_id}) when is_map(opts),
    do: start_link(Map.merge(opts, %{server_name: server_name, session_id: session_id}))

  def start_link(%{server_name: server_name, session_id: session_id} = opts) do
    opts = %{opts | server_name: to_string(server_name), session_id: to_string(session_id)}

    GenServer.start_link(__MODULE__, opts,
      name: Registry.via({:session, opts.server_name, opts.session_id})
    )
  end

  def attach_sink(server_name, session_id, sink_pid, opts \\ [])
      when is_pid(sink_pid) and is_list(opts) do
    kind = Keyword.get(opts, :kind, :get)

    unless kind in [:post, :get, :stdio],
      do: raise(ArgumentError, "sink kind must be :post, :get, or :stdio, got: #{inspect(kind)}")

    call(server_name, session_id, {:attach_sink, sink_pid, opts})
  end

  def detach_sink(server_name, session_id, sink_ref) when is_reference(sink_ref),
    do: call(server_name, session_id, {:detach_sink, sink_ref})

  def deliverable?(server_name, session_id),
    do: call(server_name, session_id, :deliverable?) == true

  def send_envelope(server_name, session_id, envelope, opts \\ [])
      when is_map(envelope) and is_list(opts),
      do: call(server_name, session_id, {:send_envelope, envelope, opts})

  def request_peer(server_name, session_id, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    if Keyword.has_key?(opts, :timeout_ms),
      do: Options.check!(opts[:timeout_ms], :pos_integer, :timeout_ms)

    # The session replies by the request's own timeout at the latest.
    call(server_name, session_id, {:request_peer, method, params, opts}, :infinity)
  end

  # Sends the client an MCP ping on the stream it listens on (a GET stream or
  # stdio), without waiting: the reply to the returned `:gen_server` request
  # id is `{:ok, %{}}` or `{:error, reason}`, `:not_deliverable` when no such
  # stream listens.
  def send_ping(pid, timeout_ms) when is_pid(pid) do
    Options.check!(timeout_ms, :pos_integer, :timeout_ms)
    message = {:request_peer, "ping", %{}, timeout_ms: timeout_ms, listening: true}
    :gen_server.send_request(pid, message)
  end

  def resolve_peer_response(server_name, session_id, request_id, payload)
      when (is_binary(request_id) or is_integer(request_id)) and is_map(payload),
      do: call(server_name, session_id, {:resolve_peer_response, request_id, payload})

  def register_inbound_request(server_name, session_id, request_id, worker_pid, opts \\ [])
      when (is_binary(request_id) or is_integer(request_id)) and is_pid(worker_pid) and
             is_list(opts),
      do: call(server_name, session_id, {:register_inbound_request, request_id, worker_pid, opts})

  def finish_inbound_request(server_name, session_id, request_id),
    do: call(server_name, session_id, {:finish_inbound_request, request_id})

  def receiver_task_started(server_name, session_id, task_id, request_id, progress_token)
      when is_binary(task_id) and task_id != "" and
             (is_binary(request_id) or is_integer(request_id)) do
    message = {:receiver_task_started, task_id, request_id, progress_token}
    call(server_name, session_id, message)
  end

  def receiver_task_finished(server_name, session_id, task_id)
      when is_binary(task_id) and task_id != "",
      do: call(server_name, session_id, {:receiver_task_finished, task_id})

  def cancel_inbound_request(server_name, session_id, request_id),
    do: call(server_name, session_id, {:cancel_inbound_request, request_id})

  def receive_peer_progress(server_name, session_id, params) when is_map(params),
    do: call(server_name, session_id, {:receive_peer_progress, params})

  def report_progress(server_name, session_id, request_id, params) when is_map(params),
    do: call(server_name, session_id, {:report_progress, request_id, params})

  def set_logging_level(server_name, session_id, level),
    do: call(server_name, session_id, {:set_logging_level, to_string(level)})

  def log(server_name, session_id, level, data, opts \\ []) when is_list(opts),
    do: call(server_name, session_id, {:log, to_string(level), data, opts})

  def cached_roots(server_name, session_id), do: call(server_name, session_id, :cached_roots)

  def cache_roots(server_name, session_id, roots) when is_list(roots),
    do: call(server_name, session_id, {:cache_roots, roots})

  def roots_changed(server_name, session_id), do: call(server_name, session_id, :roots_changed)

  def register_url_elicitation(server_name, session_id, %URLElicitation{} = elicitation),
    do: call(server_name, session_id, {:register_url_elicitation, elicitation})

  def resolve_url_elicitation(server_name, session_id, elicitation_id, action, content \\ nil) do
    message = {:resolve_url_elicitation, elicitation_id, action, content}
    call(server_name, session_id, message)
  end

  def complete_url_elicitation(server_name, session_id, elicitation_id, principal_fingerprint) do
    message = {:complete_url_elicitation, elicitation_id, principal_fingerprint}
    call(server_name, session_id, message)
  end

  def peer_task_fetch(server_name, session_id, task_id, opts) when is_list(opts),
    do: request_peer(server_name, session_id, "tasks/get", %{"taskId" => task_id}, opts)

  def peer_task_result(server_name, session_id, task_id, opts) when is_list(opts),
    do: request_peer(server_name, session_id, "tasks/result", %{"taskId" => task_id}, opts)

  def peer_task_cancel(server_name, session_id, task_id, opts) when is_list(opts),
    do: request_peer(server_name, session_id, "tasks/cancel", %{"taskId" => task_id}, opts)

  def peer_task_wait(server_name, session_id, task_id, opts) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @request_timeout_ms)
    poll_ms = Keyword.get(opts, :poll_interval_ms, 500)
    Options.check!(timeout_ms, :pos_integer, :timeout_ms)
    Options.check!(poll_ms, :pos_integer, :poll_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_peer_task_wait(server_name, session_id, task_id, opts, poll_ms, deadline)
  end

  def peer_task_on_status_change(server_name, session_id, task_id, callback)
      when is_function(callback, 1),
      do: call(server_name, session_id, {:peer_task_on_status_change, task_id, callback})

  def receive_peer_task_status(server_name, session_id, params) when is_map(params),
    do: call(server_name, session_id, {:receive_peer_task_status, params})

  def get(server_name, session_id, key, default \\ nil) do
    case call(server_name, session_id, {:state_store, :get, [key]}) do
      {:ok, value} -> value
      {:error, %Error{} = error} -> raise error
      _missing -> default
    end
  end

  def put(server_name, session_id, key, value),
    do: write_state(server_name, session_id, {:state_store, :put, [key, value]})

  def delete(server_name, session_id, key),
    do: write_state(server_name, session_id, {:state_store, :delete, [key]})

  defp write_state(server_name, session_id, message) do
    with {:error, %Error{} = error} <- call(server_name, session_id, message), do: raise(error)
  end

  def close(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :terminate_session, @termination_timeout)
      catch
        :exit, reason ->
          {:error,
           SessionStateStore.call_error(
             :delete_session,
             "session state storage",
             {:session_exit, reason}
           )}
      end

    case result do
      :ok ->
        await_termination(pid, monitor)

      {:error, %Error{}} = error ->
        Process.demonitor(monitor, [:flush])
        error
    end
  end

  def subscribe_resource(server_name, session_id, uri),
    do: call(server_name, session_id, {:subscribe_resource, to_string(uri)})

  def unsubscribe_resource(server_name, session_id, uri),
    do: call(server_name, session_id, {:unsubscribe_resource, to_string(uri)})

  def set_client_info(server_name, session_id, client_info),
    do: call(server_name, session_id, {:set_client_info, client_info})

  def client_info(server_name, session_id) do
    case lifecycle(server_name, session_id) do
      {:ok, lifecycle} -> lifecycle.client_info
      {:error, :not_found} -> nil
    end
  end

  def begin_initialization(server_name, session_id, opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :client_capabilities,
        :client_info,
        auth_identity: :unbound,
        server_capabilities: %{}
      ])

    call(server_name, session_id, {:begin_initialization, opts})
  end

  def verify_identity(server_name, session_id, identity),
    do: call(server_name, session_id, {:verify_identity, identity})

  def claim_request_id(server_name, session_id, direction, request_id)
      when direction in [:client, :server] and
             (is_binary(request_id) or is_integer(request_id)),
      do: call(server_name, session_id, {:claim_request_id, direction, request_id})

  def mark_initialized(server_name, session_id),
    do: call(server_name, session_id, :mark_initialized)

  def lifecycle(server_name, session_id), do: call(server_name, session_id, :lifecycle)

  # Every client function goes through here: a session that is gone, or stops
  # while handling the call, is `{:error, :not_found}`.
  defp call(server_name, session_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, message, timeout)
    end
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :not_found}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :not_found}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {replay_opts, opts} = Map.split(opts, Map.keys(@replay_options))
    state = struct!(__MODULE__, opts)

    state = %{
      state
      | replay:
          SSEReplay.new(
            Enum.map(replay_opts, fn {key, value} -> {@replay_options[key], value} end)
          ),
        log_rate: per_second(state.max_logs_per_second),
        peer_progress_rate: per_second(state.max_inbound_progress_per_second)
    }

    {:ok, state, idle_timeout(state)}
  end

  @impl true
  def handle_call({:attach_sink, pid, opts}, _from, state),
    do: reply_outcome(Outbox.attach(state, pid, opts))

  def handle_call({:detach_sink, sink_ref}, _from, state),
    do: reply(:ok, Outbox.detach(state, sink_ref))

  def handle_call(:deliverable?, _from, state),
    do: reply(Outbox.deliverable?(state, nil) and state.lifecycle_state == :initialized, state)

  def handle_call({:send_envelope, envelope, opts}, _from, state),
    do: reply_outcome(Outbox.emit(state, envelope, opts))

  def handle_call({:request_peer, method, params, opts}, from, state) do
    with :ok <- check_peer_request(state, method, params, opts),
         :ok <- RuntimeQuota.claim(state.runtime_quota, :pending_requests),
         {:ok, request_id, state} <- next_server_request_id(state),
         {envelope, state} = put_pending(state, request_id, from, method, params, opts),
         {:ok, state} <- send_peer_request(state, request_id, envelope, opts) do
      noreply(state)
    else
      :request_ids_exhausted ->
        RuntimeQuota.release(state.runtime_quota, :pending_requests)
        reply({:error, request_id_capacity_error()}, state)

      {:error, reason} ->
        reply({:error, reason}, state)

      {:error, reason, state} ->
        reply({:error, reason}, state)
    end
  end

  def handle_call({:resolve_peer_response, request_id, payload}, _from, state) do
    case pop_pending(state, request_id) do
      {nil, state} ->
        reply(:ignored, state)

      {pending, state} ->
        state = Outbox.acknowledge(state, request_id)
        response = normalize_peer_response(pending, payload, state)
        GenServer.reply(pending.from, response)
        reply(:ok, maybe_track_peer_task_result(state, pending, payload, response))
    end
  end

  def handle_call({:register_inbound_request, request_id, worker_pid, opts}, _from, state) do
    progress_token = Keyword.get(opts, :progress_token)

    with :ok <- check_inbound_request(state, request_id, progress_token),
         :ok <- RuntimeQuota.claim(state.runtime_quota, :active_requests) do
      monitor = Process.monitor(worker_pid)

      max_progress_per_second =
        Keyword.get(opts, :max_progress_per_second, state.max_progress_per_second)

      active = %{
        worker_pid: worker_pid,
        monitor: monitor,
        method: Keyword.get(opts, :method),
        cancellable?: Keyword.get(opts, :cancellable, true),
        task_augmented?: Keyword.get(opts, :task_augmented, false),
        progress_token: progress_token,
        last_progress: nil,
        progress_total: nil,
        progress_rate: per_second(max_progress_per_second),
        cancelled?: false
      }

      reply(:ok, %{
        state
        | active_requests: Map.put(state.active_requests, request_id, active),
          active_monitors: Map.put(state.active_monitors, monitor, request_id),
          progress_tokens: Progress.put_owner(state.progress_tokens, progress_token, request_id)
      })
    else
      error -> reply(error, state)
    end
  end

  def handle_call({:finish_inbound_request, request_id}, _from, state) do
    case pop_active(state, request_id) do
      {nil, state} -> reply(:unknown, state)
      {%{cancelled?: true}, state} -> reply(:suppress, state)
      {_active, state} -> reply(:deliver, state)
    end
  end

  def handle_call({:receiver_task_started, task_id, request_id, progress_token}, _from, state) do
    cond do
      Map.has_key?(state.receiver_tasks, task_id) ->
        reply({:error, :already_started}, state)

      progress_token != nil and
          Map.get(state.progress_tokens, progress_token) not in [nil, request_id] ->
        reply({:error, :duplicate_progress_token}, state)

      true ->
        active = Map.get(state.active_requests, request_id)

        task = %{
          request_id: request_id,
          progress_token: progress_token,
          last_progress: active && active.last_progress,
          progress_total: active && active.progress_total,
          progress_rate:
            (active && active.progress_rate) || per_second(state.max_progress_per_second)
        }

        state = %{
          state
          | receiver_tasks: Map.put(state.receiver_tasks, task_id, task),
            receiver_task_requests:
              Map.update(
                state.receiver_task_requests,
                request_id,
                MapSet.new([task_id]),
                &MapSet.put(&1, task_id)
              ),
            progress_tokens: Progress.put_owner(state.progress_tokens, progress_token, request_id)
        }

        reply(:ok, state)
    end
  end

  def handle_call({:receiver_task_finished, task_id}, _from, state) do
    case pop_receiver_task(state, task_id) do
      {nil, state} -> reply(:unknown, state)
      {_task, state} -> reply(:ok, state)
    end
  end

  def handle_call({:cancel_inbound_request, request_id}, _from, state) do
    case Map.get(state.active_requests, request_id) do
      %{method: method, task_augmented?: task?, cancellable?: cancellable?} = active
      when method != "initialize" and task? != true and cancellable? != false ->
        Process.exit(active.worker_pid, :shutdown)
        reply(:ok, put_in(state.active_requests[request_id].cancelled?, true))

      _not_cancellable ->
        reply(:ignored, state)
    end
  end

  def handle_call({:receive_peer_progress, params}, _from, state) do
    with path when path != nil <- peer_progress_path(state, params["progressToken"]),
         %{} = tracker <- get_in(state, path),
         {:ok, tracker, rate} <- Progress.update(tracker, params, state.peer_progress_rate) do
      run_callback(state, tracker.on_progress, params)
      reply(:ok, %{put_in(state, path, tracker) | peer_progress_rate: rate})
    else
      {:error, :rate_limited} = error -> reply(error, state)
      _ignored -> reply(:ignored, state)
    end
  end

  def handle_call({:report_progress, request_id, params}, _from, state) do
    with path when path != nil <- report_progress_path(state, request_id),
         tracker = get_in(state, path),
         {:ok, tracker, rate} <- Progress.update(tracker, params, tracker.progress_rate),
         params = Map.put(params, "progressToken", tracker.progress_token),
         notification = notification("notifications/progress", params),
         {:ok, _delivery, state} <- Outbox.emit(state, notification, queue: false) do
      reply(:ok, put_in(state, path, %{tracker | progress_rate: rate}))
    else
      nil -> reply({:error, :unknown_request}, state)
      {:error, reason, state} -> reply({:error, reason}, state)
      {:error, reason} -> reply({:error, reason}, state)
    end
  end

  def handle_call({:set_logging_level, level}, _from, state) do
    if Meta.log_level_rank(level) do
      reply(:ok, %{state | logging_level: level})
    else
      reply({:error, :invalid_level}, state)
    end
  end

  def handle_call({:log, level, data, opts}, _from, state) do
    rank = Meta.log_level_rank(level)

    cond do
      is_nil(rank) ->
        reply({:error, :invalid_level}, state)

      rank < Meta.log_level_rank(state.logging_level) ->
        reply(:filtered, state)

      true ->
        case SlidingWindow.acquire(state.log_rate, System.monotonic_time(:millisecond)) do
          {:error, _wait_ms, _rate} ->
            reply({:error, :rate_limited}, state)

          {:ok, rate} ->
            params =
              %{
                "level" => level,
                "data" => Redactor.redact(data, Keyword.merge(state.redaction_opts, opts))
              }
              |> maybe_put("logger", Keyword.get(opts, :logger))

            state = %{state | log_rate: rate}

            case Outbox.emit(state, notification("notifications/message", params), queue: true) do
              {:ok, _delivery, state} -> reply({:ok, params["data"]}, state)
              error -> reply_outcome(error)
            end
        end
    end
  end

  def handle_call({:peer_task_on_status_change, task_id, callback}, from, state) do
    cond do
      map_size(state.peer_task_callback_monitors) >= state.max_peer_task_callbacks ->
        reply({:error, :overloaded}, state)

      not Map.has_key?(state.peer_tasks, task_id) ->
        reply({:error, :not_found}, state)

      terminal_peer_task?(Map.get(state.peer_tasks, task_id)) ->
        reply({:error, :task_terminal}, state)

      true ->
        {owner, _tag} = from
        ref = make_ref()
        monitor = Process.monitor(owner)
        entry = %{callback: callback, monitor: monitor}

        reply(:ok, %{
          state
          | peer_task_callbacks:
              Map.update(
                state.peer_task_callbacks,
                task_id,
                %{ref => entry},
                &Map.put(&1, ref, entry)
              ),
            peer_task_callback_monitors:
              Map.put(state.peer_task_callback_monitors, monitor, {task_id, ref})
        })
    end
  end

  def handle_call({:receive_peer_task_status, params}, _from, state) do
    case params["taskId"] do
      task_id when is_binary(task_id) and task_id != "" ->
        existing = Map.get(state.peer_tasks, task_id)

        if is_nil(existing) or terminal_peer_task?(existing) do
          reply(:ignored, state)
        else
          Enum.each(Map.get(state.peer_task_callbacks, task_id, %{}), fn {_ref, entry} ->
            run_callback(state, entry.callback, params)
          end)

          reply(
            :ok,
            track_peer_task(state, params, "notifications/tasks/status", existing.context)
          )
        end

      _other ->
        reply({:error, :invalid_task_status}, state)
    end
  end

  def handle_call(:cached_roots, _from, state), do: reply(state.roots, state)

  def handle_call({:cache_roots, roots}, _from, state) do
    case normalize_roots(roots) do
      {:ok, roots} -> reply({:ok, roots}, %{state | roots: roots})
      {:error, reason} -> reply({:error, reason}, state)
    end
  end

  def handle_call(:roots_changed, _from, state) do
    state = %{state | roots: nil}
    maybe_refresh_roots(state)
    reply(:ok, state)
  end

  def handle_call({:register_url_elicitation, elicitation}, _from, state) do
    id = elicitation.elicitation_id

    if Map.has_key?(state.url_elicitations, id) do
      reply({:error, :already_exists}, state)
    else
      case Registry.register_url_elicitation(state.server_name, id, state.session_id) do
        :ok -> reply(:ok, put_url_elicitation(state, elicitation))
        {:error, :already_exists} = error -> reply(error, state)
      end
    end
  end

  def handle_call({:resolve_url_elicitation, id, action, content}, _from, state) do
    case Map.fetch(state.url_elicitations, id) do
      :error ->
        reply({:error, :not_found}, state)

      {:ok, elicitation} ->
        case URLElicitation.respond(elicitation, action, content) do
          {:ok, %{action: action} = updated} when action in [:decline, :cancel] ->
            reply({:ok, updated}, drop_url_elicitation(state, id))

          {:ok, updated} ->
            reply({:ok, updated}, put_url_elicitation(state, updated))

          {:error, :expired} ->
            reply({:error, :expired}, drop_url_elicitation(state, id))

          {:error, reason} ->
            reply({:error, reason}, state)
        end
    end
  end

  def handle_call({:complete_url_elicitation, id, principal_fingerprint}, _from, state) do
    case Map.fetch(state.url_elicitations, id) do
      :error ->
        reply({:error, :not_found}, state)

      {:ok, elicitation} ->
        case URLElicitation.complete(elicitation, state.session_id, principal_fingerprint) do
          {:ok, updated} ->
            state = put_url_elicitation(state, updated)
            {:ok, params} = URLElicitation.completion_params(updated)

            notification = notification("notifications/elicitation/complete", params)

            case Outbox.emit(state, notification, queue: true) do
              {:ok, _delivery, state} -> reply({:ok, updated}, state)
              error -> reply_outcome(error)
            end

          {:error, :expired} ->
            reply({:error, :expired}, drop_url_elicitation(state, id))

          {:error, reason} ->
            reply({:error, reason}, state)
        end
    end
  end

  def handle_call({:state_store, operation, args}, _from, state),
    do: reply(state_store(state, operation, args), state)

  def handle_call(:terminate_session, _from, state) do
    case state_store(state, :delete_session, []) do
      :ok -> {:stop, :normal, :ok, state}
      {:error, %Error{}} = error -> reply(error, state)
    end
  end

  def handle_call({:subscribe_resource, uri}, _from, state),
    do:
      reply(:ok, %{state | resource_subscriptions: MapSet.put(state.resource_subscriptions, uri)})

  def handle_call({:unsubscribe_resource, uri}, _from, state),
    do:
      reply(:ok, %{
        state
        | resource_subscriptions: MapSet.delete(state.resource_subscriptions, uri)
      })

  def handle_call({:set_client_info, client_info}, _from, state),
    do:
      reply(:ok, %{state | client_info: Map.new(client_info, fn {k, v} -> {to_string(k), v} end)})

  def handle_call({:begin_initialization, opts}, _from, %{lifecycle_state: :new} = state) do
    reply(:ok, %{
      state
      | lifecycle_state: :initializing,
        protocol_version: legacy(),
        client_capabilities: normalize_client_capabilities(opts[:client_capabilities]),
        server_capabilities: Protocol.normalize_capabilities(opts[:server_capabilities]),
        client_info: opts[:client_info],
        auth_identity: opts[:auth_identity]
    })
  end

  def handle_call(:mark_initialized, _from, %{lifecycle_state: :initializing} = state),
    do: reply(:ok, %{state | lifecycle_state: :initialized})

  def handle_call({:begin_initialization, _opts}, _from, state), do: invalid_transition(state)
  def handle_call(:mark_initialized, _from, state), do: invalid_transition(state)

  def handle_call({:verify_identity, identity}, _from, %{auth_identity: :unbound} = state),
    do: reply(:ok, %{state | auth_identity: identity})

  def handle_call({:verify_identity, identity}, _from, %{auth_identity: identity} = state),
    do: reply(:ok, state)

  def handle_call({:verify_identity, _identity}, _from, state),
    do: reply({:error, :identity_mismatch}, state)

  def handle_call({:claim_request_id, direction, request_id}, _from, state) do
    key = if direction == :client, do: :client_request_ids, else: :server_request_ids
    request_ids = Map.fetch!(state, key)

    cond do
      MapSet.member?(request_ids, request_id) ->
        reply({:error, :duplicate}, state)

      MapSet.size(request_ids) >= state.max_request_ids ->
        reply({:error, :overloaded}, state)

      true ->
        reply(:ok, Map.put(state, key, MapSet.put(request_ids, request_id)))
    end
  end

  def handle_call(:lifecycle, _from, state) do
    lifecycle = %{
      state: state.lifecycle_state,
      protocol_version: state.protocol_version,
      client_capabilities: state.client_capabilities,
      server_capabilities: state.server_capabilities,
      client_info: state.client_info
    }

    reply({:ok, lifecycle}, state)
  end

  @impl true
  def handle_info({:peer_request_timeout, request_id}, state) do
    case pop_pending(state, request_id) do
      {nil, state} ->
        noreply(state)

      {pending, state} ->
        state = emit_cancellation(state, request_id, "server request timed out", pending.sink_ref)
        GenServer.reply(pending.from, {:error, :timeout})
        noreply(state)
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      sink_ref = Map.get(state.sink_monitors, monitor) ->
        noreply(Outbox.detach(state, sink_ref))

      request_id = Map.get(state.pending_monitors, monitor) ->
        {pending, state} = pop_pending(state, request_id)

        noreply(
          emit_cancellation(
            state,
            request_id,
            "server request caller terminated",
            pending.sink_ref
          )
        )

      request_id = Map.get(state.active_monitors, monitor) ->
        {_active, state} = pop_active(state, request_id)
        noreply(state)

      callback_key = Map.get(state.peer_task_callback_monitors, monitor) ->
        noreply(drop_peer_task_callback(state, monitor, callback_key))

      true ->
        Logger.debug("session ignored unknown process DOWN: #{inspect({pid, reason})}")
        noreply(state)
    end
  end

  # While a GET or stdio stream listens, server events become notifications.
  def handle_info(
        {:fastest_mcp_event, _server_name, event_suffix, _measurements, metadata},
        state
      ) do
    if Outbox.listening?(state) do
      capabilities =
        if state.lifecycle_state == :initialized, do: state.server_capabilities, else: %{}

      listener =
        Notifications.session_listener(
          state.session_id,
          capabilities || %{},
          state.resource_subscriptions
        )

      event_suffix
      |> Notifications.notifications(metadata, listener)
      |> Enum.reduce(state, &(&2 |> Outbox.emit(&1, queue: true) |> elem(2)))
      |> noreply()
    else
      noreply(state)
    end
  end

  # The idle timeout of `reply/2` and `noreply/1` elapsed.
  def handle_info(:timeout, state) do
    case state_store(state, :delete_session, []) do
      :ok ->
        {:stop, :normal, state}

      {:error, %Error{} = error} ->
        Logger.error(
          "session #{inspect(state.session_id)} idle cleanup failed: #{Exception.message(error)}"
        )

        noreply(state)
    end
  end

  @impl true
  def terminate(reason, state) do
    # The runtime quota goes back first, so that a session killed while it
    # deletes its stored state below, as after a shutdown timeout, keeps none.
    RuntimeQuota.release(state.runtime_quota, :pending_requests, map_size(state.pending_requests))
    RuntimeQuota.release(state.runtime_quota, :active_requests, map_size(state.active_requests))
    Outbox.close(state)

    for {_request_id, pending} <- state.pending_requests,
        do: GenServer.reply(pending.from, {:error, :session_terminated})

    for {_request_id, active} <- state.active_requests,
        do: Process.exit(active.worker_pid, :shutdown)

    # Server shutdown stops sessions with :shutdown; their stored state goes
    # with them while the state store is still running.
    if reason == :shutdown or match?({:shutdown, _}, reason) do
      with {:error, %Error{} = error} <- state_store(state, :delete_session, []) do
        Logger.error(
          "failed to delete state for session #{inspect(state.session_id)} during shutdown: " <>
            Exception.message(error)
        )
      end
    end
  end

  defp reply(reply, state), do: {:reply, reply, state, idle_timeout(state)}
  defp noreply(state), do: {:noreply, state, idle_timeout(state)}

  defp reply_outcome({:ok, value, state}), do: reply({:ok, value}, state)
  defp reply_outcome({:error, reason, state}), do: reply({:error, reason}, state)

  defp invalid_transition(state),
    do: reply({:error, {:invalid_transition, state.lifecycle_state}}, state)

  # A session expires once it has received no message for `idle_ttl_ms`, but
  # never while it holds a sink, a request, or an unfinished task.
  defp idle_timeout(state) do
    held? =
      map_size(state.sinks) > 0 or map_size(state.pending_requests) > 0 or
        map_size(state.active_requests) > 0 or map_size(state.receiver_tasks) > 0 or
        Enum.any?(state.peer_tasks, fn {_task_id, peer_task} ->
          not terminal_peer_task?(peer_task)
        end)

    if held?, do: :infinity, else: state.idle_ttl_ms
  end

  defp state_store(state, operation, args) do
    SessionStateStore.call(operation, "session state storage", fn ->
      apply(SessionStateStore, operation, [state.session_state_store, state.session_id | args])
    end)
  end

  defp await_termination(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      @termination_timeout ->
        Process.demonitor(monitor, [:flush])

        {:error,
         %Error{
           code: :internal_error,
           message: "session did not terminate after state deletion",
           details: %{session_pid: inspect(pid)}
         }}
    end
  end

  defp check_peer_request(state, method, params, opts) do
    progress_token = Keyword.get(opts, :progress_token)

    cond do
      state.lifecycle_state != :initialized ->
        {:error, :not_initialized}

      not Protocol.client_supports_method?(state.client_capabilities, method, params) ->
        {:error, :unsupported_capability}

      map_size(state.pending_requests) >= state.max_pending_requests ->
        {:error, :overloaded}

      Map.has_key?(params, "task") and peer_task_capacity_reached?(state) ->
        {:error, :overloaded}

      progress_token != nil and Map.has_key?(state.peer_progress_tokens, progress_token) ->
        {:error, :duplicate_progress_token}

      not Outbox.deliverable?(state, Keyword.get(opts, :sink_ref)) ->
        {:error, :not_deliverable}

      Keyword.get(opts, :listening, false) and not Outbox.listening?(state) ->
        {:error, :not_deliverable}

      true ->
        :ok
    end
  end

  defp check_inbound_request(state, request_id, progress_token) do
    cond do
      map_size(state.active_requests) >= state.max_active_requests ->
        {:error, :overloaded}

      Map.has_key?(state.active_requests, request_id) ->
        {:error, :duplicate}

      progress_token != nil and Map.has_key?(state.progress_tokens, progress_token) ->
        {:error, :duplicate_progress_token}

      true ->
        :ok
    end
  end

  defp next_server_request_id(state) do
    request_id = "srv-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    cond do
      MapSet.size(state.server_request_ids) >= state.max_request_ids ->
        :request_ids_exhausted

      MapSet.member?(state.server_request_ids, request_id) ->
        next_server_request_id(state)

      true ->
        {:ok, request_id,
         %{state | server_request_ids: MapSet.put(state.server_request_ids, request_id)}}
    end
  end

  defp request_id_capacity_error do
    %Error{
      code: :overloaded,
      message: "JSON-RPC request id capacity has been reached",
      details: %{resource: :request_ids, retry_after_seconds: 1},
      terminate_session_after_delivery: true
    }
  end

  # Tracks a peer request until its response, its timeout, or its caller's exit.
  defp put_pending(state, request_id, {caller_pid, _tag} = from, method, params, opts) do
    progress_token = Keyword.get(opts, :progress_token)
    params = put_request_progress_token(params, progress_token)
    caller_monitor = Process.monitor(caller_pid)
    timeout_ms = Keyword.get(opts, :timeout_ms, state.request_timeout_ms)

    pending = %{
      from: from,
      caller_monitor: caller_monitor,
      timer: Process.send_after(self(), {:peer_request_timeout, request_id}, timeout_ms),
      method: method,
      task_augmented: Map.has_key?(params, "task"),
      peer_task_id: params["taskId"],
      peer_task_context: peer_task_context(method, params),
      sink_ref: Keyword.get(opts, :sink_ref),
      progress_token: progress_token,
      on_progress: Keyword.get(opts, :on_progress),
      last_progress: nil,
      progress_total: nil
    }

    state = %{
      state
      | pending_requests: Map.put(state.pending_requests, request_id, pending),
        pending_monitors: Map.put(state.pending_monitors, caller_monitor, request_id),
        peer_progress_tokens:
          Progress.put_owner(state.peer_progress_tokens, progress_token, {:request, request_id})
    }

    {%{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}, state}
  end

  defp send_peer_request(state, request_id, envelope, opts) do
    delivery = [
      sink_ref: Keyword.get(opts, :sink_ref),
      origin_request_id: Keyword.get(opts, :origin_request_id),
      request_id: request_id
    ]

    with :ok <- validate_outbound_peer_request(envelope, opts),
         {:ok, _delivery, state} <- Outbox.emit(state, envelope, delivery) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, elem(pop_pending(state, request_id), 1)}
      {:error, reason, state} -> {:error, reason, elem(pop_pending(state, request_id), 1)}
    end
  end

  defp pop_pending(state, request_id) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending_requests} ->
        {nil, state}

      {pending, pending_requests} ->
        Process.cancel_timer(pending.timer, async: true, info: false)
        Process.demonitor(pending.caller_monitor, [:flush])
        RuntimeQuota.release(state.runtime_quota, :pending_requests)

        {pending,
         %{
           state
           | pending_requests: pending_requests,
             pending_monitors: Map.delete(state.pending_monitors, pending.caller_monitor),
             peer_progress_tokens:
               Progress.delete_owner(
                 state.peer_progress_tokens,
                 pending.progress_token,
                 {:request, request_id}
               )
         }}
    end
  end

  defp normalize_peer_response(pending, payload, state) do
    validation =
      with :ok <- validate_protocol_meta(payload, :peer),
           :ok <-
             validate_peer_response_schema(
               pending.method,
               pending.task_augmented,
               payload
             ),
           :ok <- validate_peer_task_result_schema(state, pending, payload) do
        :ok
      end

    case validation do
      :ok ->
        normalize_valid_peer_response(payload)

      {:error, {method, %FastestMCP.Schema.Error{} = error}} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "invalid #{method} response from client",
           details: %{violations: error.violations}
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_peer_response_schema(method, task_augmented, payload) do
    kind = if task_augmented, do: :task_response, else: :response

    validation =
      if ProtocolSchema.supported?(
           legacy(),
           :client_to_server,
           kind,
           method
         ) do
        ProtocolSchema.validate(
          legacy(),
          :client_to_server,
          kind,
          method,
          payload
        )
      else
        ProtocolSchema.validate(
          legacy(),
          :client_to_server,
          :response,
          payload
        )
      end

    case validation do
      {:ok, ^payload} -> :ok
      {:error, %FastestMCP.Schema.Error{} = error} -> {:error, {method, error}}
    end
  end

  defp validate_peer_task_result_schema(
         state,
         %{method: "tasks/result", peer_task_id: task_id},
         payload
       ) do
    case get_in(state.peer_tasks, [task_id, :source_method]) do
      method when method in ["sampling/createMessage", "elicitation/create"] ->
        with :ok <- validate_peer_response_schema(method, false, payload) do
          validate_peer_task_result_semantics(state, task_id, method, payload)
        end

      _unknown_or_unaugmented_task ->
        :ok
    end
  end

  defp validate_peer_task_result_schema(_state, _pending, _payload), do: :ok

  defp validate_peer_task_result_semantics(
         state,
         task_id,
         "sampling/createMessage",
         %{"result" => %{} = result}
       ) do
    context = get_in(state.peer_tasks, [task_id, :context]) || %{}

    with :ok <-
           ProtocolSampling.validate_result(
             result,
             Map.get(context, :sampling_tool_choice, :auto)
           ),
         {:ok, validators} <-
           ProtocolSampling.compile_tool_validators(Map.get(context, :sampling_tools)),
         :ok <- ProtocolSampling.validate_tool_inputs(result, validators) do
      :ok
    else
      {:error, message} when is_binary(message) ->
        {:error, %Error{code: :bad_request, message: message}}

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "sampling request retained an invalid tool inputSchema",
           details: %{violations: error.violations}
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, {:unknown_tool, name}} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling task result selected an unknown tool",
           details: %{tool: name}
         }}

      {:error, {:invalid_tool_input, name, %FastestMCP.Schema.Error{} = error}} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling task result tool input is outside inputSchema",
           details: %{tool: name, violations: error.violations}
         }}
    end
  end

  defp validate_peer_task_result_semantics(_state, _task_id, _method, _payload), do: :ok

  defp normalize_valid_peer_response(%{"result" => %{} = result}), do: {:ok, result}

  defp normalize_valid_peer_response(%{
         "error" => %{"code" => code, "message" => message} = error
       })
       when is_integer(code) and is_binary(message) do
    {:error,
     %Error{
       code: :peer_error,
       message: message,
       details: %{peer_code: code, peer_data: Map.get(error, "data")}
     }}
  end

  defp normalize_valid_peer_response(_payload), do: {:error, :invalid_response}

  defp validate_outbound_peer_request(%{"method" => method} = envelope, opts) do
    related_task_id = Keyword.get(opts, :protocol_related_task_id)

    allowed_reserved =
      if is_binary(related_task_id), do: ["io.modelcontextprotocol/related-task"], else: []

    with :ok <- validate_protocol_related_task(envelope, related_task_id),
         :ok <- validate_protocol_meta(envelope, :application, allowed_reserved) do
      if ProtocolSchema.supported?(
           legacy(),
           :server_to_client,
           :request,
           method
         ) do
        case ProtocolSchema.validate(
               legacy(),
               :server_to_client,
               :request,
               method,
               envelope
             ) do
          {:ok, ^envelope} ->
            :ok

          {:error, %FastestMCP.Schema.Error{} = error} ->
            {:error,
             %Error{
               code: :internal_error,
               message: "invalid outbound #{method} request",
               details: %{violations: error.violations}
             }}
        end
      else
        :ok
      end
    end
  end

  defp validate_protocol_meta(payload, source, allowed_reserved \\ []) do
    case Meta.validate_tree(payload, source: source, allowed_reserved: allowed_reserved) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: reason,
           details: %{jsonrpc_code: -32_602}
         }}
    end
  end

  defp validate_protocol_related_task(payload, expected_task_id) do
    case collect_related_task_ids(payload, []) do
      [] ->
        :ok

      task_ids when is_binary(expected_task_id) ->
        if Enum.all?(task_ids, &(&1 == expected_task_id)) do
          :ok
        else
          {:error,
           %Error{
             code: :invalid_params,
             message: "related-task metadata does not match the active task",
             details: %{jsonrpc_code: -32_602}
           }}
        end

      _task_ids ->
        :ok
    end
  end

  defp collect_related_task_ids(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn
      {key, meta}, ids when key in ["_meta", :_meta] and is_map(meta) ->
        ids =
          case Map.get(meta, "io.modelcontextprotocol/related-task") do
            %{} = related ->
              [Map.get(related, "taskId") | ids]

            _other ->
              ids
          end

        collect_related_task_ids(meta, ids)

      {_key, child}, ids ->
        collect_related_task_ids(child, ids)
    end)
  end

  defp collect_related_task_ids(value, acc) when is_list(value),
    do: Enum.reduce(value, acc, &collect_related_task_ids/2)

  defp collect_related_task_ids(_value, acc), do: acc

  defp emit_cancellation(state, request_id, reason, sink_ref) do
    params = %{"requestId" => request_id, "reason" => reason}

    outcome =
      Outbox.emit(state, notification("notifications/cancelled", params), sink_ref: sink_ref)

    elem(outcome, 2)
  end

  defp pop_active(state, request_id) do
    case Map.pop(state.active_requests, request_id) do
      {nil, active_requests} ->
        {nil, %{state | active_requests: active_requests}}

      {active, active_requests} ->
        RuntimeQuota.release(state.runtime_quota, :active_requests)
        Process.demonitor(active.monitor, [:flush])

        receiver_task_ids = Map.get(state.receiver_task_requests, request_id, MapSet.new())
        preserve_progress? = MapSet.size(receiver_task_ids) > 0

        receiver_tasks =
          Enum.reduce(receiver_task_ids, state.receiver_tasks, fn task_id, tasks ->
            Map.update(tasks, task_id, nil, fn task ->
              %{
                task
                | last_progress: active.last_progress,
                  progress_total: active.progress_total,
                  progress_rate: active.progress_rate
              }
            end)
          end)

        state = %{
          state
          | active_requests: active_requests,
            active_monitors: Map.delete(state.active_monitors, active.monitor),
            receiver_tasks: receiver_tasks,
            progress_tokens:
              if(preserve_progress?,
                do: state.progress_tokens,
                else:
                  Progress.delete_owner(
                    state.progress_tokens,
                    active.progress_token,
                    request_id
                  )
              )
        }

        {active, state}
    end
  end

  defp put_request_progress_token(params, nil), do: params

  defp put_request_progress_token(params, token) do
    case Map.get(params, "_meta", %{}) do
      meta when is_map(meta) -> Map.put(params, "_meta", Map.put(meta, "progressToken", token))
      _invalid_meta -> params
    end
  end

  defp pop_receiver_task(state, task_id) do
    case Map.pop(state.receiver_tasks, task_id) do
      {nil, receiver_tasks} ->
        {nil, %{state | receiver_tasks: receiver_tasks}}

      {task, receiver_tasks} ->
        task_ids =
          state.receiver_task_requests
          |> Map.get(task.request_id, MapSet.new())
          |> MapSet.delete(task_id)

        receiver_task_requests =
          if MapSet.size(task_ids) == 0 do
            Map.delete(state.receiver_task_requests, task.request_id)
          else
            Map.put(state.receiver_task_requests, task.request_id, task_ids)
          end

        progress_tokens =
          if MapSet.size(task_ids) == 0 and
               not Map.has_key?(state.active_requests, task.request_id) do
            Progress.delete_owner(
              state.progress_tokens,
              task.progress_token,
              task.request_id
            )
          else
            state.progress_tokens
          end

        {task,
         %{
           state
           | receiver_tasks: receiver_tasks,
             receiver_task_requests: receiver_task_requests,
             progress_tokens: progress_tokens
         }}
    end
  end

  defp per_second(limit), do: SlidingWindow.new(limit, 1_000)

  # Where the progress behind a peer's progress token is tracked.
  defp peer_progress_path(state, token) do
    case Map.get(state.peer_progress_tokens, token) do
      {:request, request_id} -> [Access.key!(:pending_requests), request_id]
      {:task, task_id} -> [Access.key!(:peer_tasks), task_id, :context]
      nil -> nil
    end
  end

  # An inbound request reports its own progress; its receiver task continues
  # reporting it once the request returned.
  defp report_progress_path(state, request_id) do
    cond do
      Map.has_key?(state.active_requests, request_id) ->
        [Access.key!(:active_requests), request_id]

      task_id = receiver_task_id(state, request_id) ->
        [Access.key!(:receiver_tasks), task_id]

      true ->
        nil
    end
  end

  defp receiver_task_id(state, request_id) do
    state.receiver_task_requests
    |> Map.get(request_id, MapSet.new())
    |> Enum.find(&Map.has_key?(state.receiver_tasks, &1))
  end

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp run_callback(_state, nil, _params), do: :ok

  defp run_callback(%{task_supervisor: supervisor}, callback, params)
       when is_pid(supervisor) and is_function(callback, 1) do
    _ = Task.Supervisor.start_child(supervisor, fn -> callback.(params) end)
    :ok
  end

  defp run_callback(_state, _callback, _params), do: :ok

  defp normalize_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case Root.parse(root) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp maybe_refresh_roots(%{task_supervisor: supervisor} = state) when is_pid(supervisor) do
    server_name = state.server_name
    session_id = state.session_id

    _ =
      Task.Supervisor.start_child(supervisor, fn ->
        case request_peer(server_name, session_id, "roots/list", %{}, timeout_ms: 60_000) do
          {:ok, %{"roots" => roots}} when is_list(roots) ->
            _ = cache_roots(server_name, session_id, roots)
            :ok

          _other ->
            :ok
        end
      end)

    :ok
  end

  defp maybe_refresh_roots(_state), do: :ok

  defp put_url_elicitation(state, elicitation) do
    %{
      state
      | url_elicitations: Map.put(state.url_elicitations, elicitation.elicitation_id, elicitation)
    }
  end

  defp drop_url_elicitation(state, elicitation_id) do
    :ok = Registry.unregister_url_elicitation(state.server_name, elicitation_id)

    %{state | url_elicitations: Map.delete(state.url_elicitations, elicitation_id)}
  end

  defp maybe_track_peer_task_result(
         state,
         pending,
         %{"result" => %{"task" => task}},
         {:ok, _result}
       )
       when is_map(task) do
    context = peer_task_progress_context(pending)
    track_peer_task(state, task, pending.method, context)
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: method},
         %{"result" => %{} = task},
         {:ok, _result}
       )
       when method == "tasks/get" do
    track_peer_task(state, task, method)
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: "tasks/list"},
         %{"result" => %{"tasks" => tasks}},
         {:ok, _result}
       )
       when is_list(tasks) do
    Enum.reduce(tasks, state, fn task, current ->
      track_peer_task(current, task, "tasks/list")
    end)
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: "tasks/cancel"},
         %{"result" => %{} = task},
         {:ok, _result}
       ) do
    track_peer_task(state, task, "tasks/cancel")
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: "tasks/result"} = pending,
         %{"result" => %{} = result},
         {:ok, _result}
       ) do
    state
    |> resolve_peer_url_task(pending.peer_task_id, result)
    |> drop_peer_task(pending.peer_task_id)
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: "tasks/result"} = pending,
         %{"error" => %{}},
         {:error, %Error{code: :peer_error}}
       ) do
    state
    |> release_peer_url_task(pending.peer_task_id)
    |> drop_peer_task(pending.peer_task_id)
  end

  defp maybe_track_peer_task_result(
         state,
         %{method: method} = pending,
         %{"error" => %{"code" => -32_602}},
         {:error, %Error{code: :peer_error}}
       )
       when method in ["tasks/get", "tasks/cancel"] do
    state
    |> release_peer_url_task(pending.peer_task_id)
    |> drop_peer_task(pending.peer_task_id)
  end

  defp maybe_track_peer_task_result(state, _pending, _payload, _response), do: state

  defp peer_task_progress_context(pending) do
    case pending.progress_token do
      nil ->
        pending.peer_task_context

      token ->
        Map.merge(pending.peer_task_context, %{
          progress_token: token,
          on_progress: pending.on_progress,
          last_progress: pending.last_progress,
          progress_total: pending.progress_total
        })
    end
  end

  defp track_peer_task(state, task, source_method, context \\ %{}) do
    task_id = task["taskId"]

    state
    |> put_peer_task(task, source_method, context)
    |> maybe_release_terminal_peer_url(task_id, task)
    |> maybe_finalize_terminal_peer_task(task_id, task)
  end

  defp put_peer_task(state, task, source_method, context) do
    case task["taskId"] do
      task_id when is_binary(task_id) and task_id != "" ->
        existing = Map.get(state.peer_tasks, task_id)

        cond do
          terminal_peer_task?(existing) ->
            state

          is_nil(existing) and map_size(state.peer_tasks) >= state.max_peer_tasks ->
            state

          true ->
            existing_context = if existing, do: existing.context, else: %{}
            context = Map.merge(existing_context, context)

            peer_task = %{
              task: task,
              source_method: if(existing, do: existing.source_method, else: source_method),
              context: context
            }

            state = %{state | peer_tasks: Map.put(state.peer_tasks, task_id, peer_task)}
            claim_peer_task_progress(state, task_id, context)
        end

      _other ->
        state
    end
  end

  defp drop_peer_task(state, task_id) when is_binary(task_id) do
    state
    |> release_peer_task_progress(task_id)
    |> Map.update!(:peer_tasks, &Map.delete(&1, task_id))
    |> drop_peer_task_callbacks(task_id)
  end

  defp drop_peer_task(state, _task_id), do: state

  defp claim_peer_task_progress(state, task_id, context) do
    case Map.get(context, :progress_token) do
      nil ->
        state

      token ->
        owner = {:task, task_id}

        if Map.get(state.peer_progress_tokens, token) in [nil, owner] do
          %{state | peer_progress_tokens: Map.put(state.peer_progress_tokens, token, owner)}
        else
          state
        end
    end
  end

  defp release_peer_task_progress(state, task_id) do
    token = get_in(state.peer_tasks, [task_id, :context, :progress_token])

    %{
      state
      | peer_progress_tokens:
          Progress.delete_owner(state.peer_progress_tokens, token, {:task, task_id})
    }
  end

  defp peer_task_context("elicitation/create", %{
         "mode" => "url",
         "elicitationId" => elicitation_id
       })
       when is_binary(elicitation_id) and elicitation_id != "",
       do: %{url_elicitation_id: elicitation_id}

  defp peer_task_context("sampling/createMessage", params) do
    %{
      sampling_tool_choice: Map.get(params, "toolChoice", :auto),
      sampling_tools: Map.get(params, "tools")
    }
  end

  defp peer_task_context(_method, _params), do: %{}

  defp resolve_peer_url_task(state, task_id, %{"action" => action} = result)
       when action in ["accept", "decline", "cancel"] do
    case peer_url_elicitation_id(state, task_id) do
      nil ->
        state

      elicitation_id ->
        case Map.fetch(state.url_elicitations, elicitation_id) do
          :error ->
            state

          {:ok, elicitation} ->
            case URLElicitation.respond(elicitation, action, Map.get(result, "content")) do
              {:ok, %{action: action}} when action in [:decline, :cancel] ->
                drop_url_elicitation(state, elicitation_id)

              {:ok, updated} ->
                put_url_elicitation(state, updated)

              {:error, :expired} ->
                drop_url_elicitation(state, elicitation_id)

              {:error, _reason} ->
                state
            end
        end
    end
  end

  defp resolve_peer_url_task(state, _task_id, _result), do: state

  defp maybe_release_terminal_peer_url(state, task_id, task) do
    if task["status"] in ["failed", "cancelled"] do
      release_peer_url_task(state, task_id)
    else
      state
    end
  end

  defp release_peer_url_task(state, task_id) do
    case peer_url_elicitation_id(state, task_id) do
      nil -> state
      elicitation_id -> drop_url_elicitation(state, elicitation_id)
    end
  end

  defp peer_url_elicitation_id(state, task_id),
    do: get_in(state.peer_tasks, [task_id, :context, :url_elicitation_id])

  defp terminal_peer_task?(nil), do: false

  defp terminal_peer_task?(%{task: task}), do: terminal_task_status?(task)

  defp peer_task_capacity_reached?(state) do
    reservations =
      Enum.count(state.pending_requests, fn {_request_id, pending} -> pending.task_augmented end)

    map_size(state.peer_tasks) + reservations >= state.max_peer_tasks
  end

  defp maybe_finalize_terminal_peer_task(state, task_id, task) do
    if terminal_task_status?(task) do
      state
      |> release_peer_task_progress(task_id)
      |> drop_peer_task_callbacks(task_id)
    else
      state
    end
  end

  defp terminal_task_status?(task), do: task["status"] in ["completed", "failed", "cancelled"]

  defp drop_peer_task_callbacks(state, task_id) do
    {callbacks, remaining} = Map.pop(state.peer_task_callbacks, task_id, %{})

    monitors =
      for {_callback_ref, %{monitor: monitor}} <- callbacks do
        Process.demonitor(monitor, [:flush])
        monitor
      end

    %{
      state
      | peer_task_callbacks: remaining,
        peer_task_callback_monitors: Map.drop(state.peer_task_callback_monitors, monitors)
    }
  end

  # The owner of a status callback exited.
  defp drop_peer_task_callback(state, monitor, {task_id, callback_ref}) do
    callbacks = Map.delete(state.peer_task_callbacks[task_id], callback_ref)

    %{
      state
      | peer_task_callbacks:
          if(callbacks == %{},
            do: Map.delete(state.peer_task_callbacks, task_id),
            else: Map.put(state.peer_task_callbacks, task_id, callbacks)
          ),
        peer_task_callback_monitors: Map.delete(state.peer_task_callback_monitors, monitor)
    }
  end

  defp do_peer_task_wait(server_name, session_id, task_id, opts, poll_interval, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      request_opts =
        Keyword.put(opts, :timeout_ms, min(remaining, Keyword.get(opts, :timeout_ms, remaining)))

      case peer_task_fetch(server_name, session_id, task_id, request_opts) do
        {:ok, %{"status" => status} = task}
        when status in ["completed", "failed", "cancelled"] ->
          {:ok, task}

        {:ok, %{"task" => %{"status" => status} = task}}
        when status in ["completed", "failed", "cancelled"] ->
          {:ok, task}

        {:ok, _task} ->
          receive do
          after
            min(poll_interval, max(remaining, 1)) -> :ok
          end

          do_peer_task_wait(server_name, session_id, task_id, opts, poll_interval, deadline)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # MCP 2025-11-25 retains the pre-mode elicitation capability spelling:
  # `elicitation: {}` is semantically equivalent to `elicitation.form: {}`.
  # Store effective capabilities so every callback gate sees one canonical form.
  defp normalize_client_capabilities(%{"elicitation" => elicitation} = capabilities)
       when is_map(elicitation) and map_size(elicitation) == 0 do
    put_in(capabilities, ["elicitation"], %{"form" => %{}})
  end

  defp normalize_client_capabilities(capabilities), do: capabilities
end
