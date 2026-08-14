defmodule FastestMCP.Session do
  @moduledoc """
  Stores per-session lifecycle metadata with idle expiry.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.

  User-facing session values are stored in the configured
  `FastestMCP.SessionStateStore` backend. This process keeps the parts that are
  inherently local to the runtime:

    * session registration
    * idle expiry and touch timestamps
    * negotiated client info
    * exact resource subscriptions
  """

  use GenServer

  alias FastestMCP.Elicitation.URL, as: URLElicitation
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Protocol.Progress, as: ProtocolProgress
  alias FastestMCP.Protocol.RateWindow
  alias FastestMCP.Protocol.Redactor
  alias FastestMCP.Protocol.Sampling, as: ProtocolSampling
  alias FastestMCP.Registry
  alias FastestMCP.Root
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.Schema
  alias FastestMCP.SessionStateStore
  alias FastestMCP.SSEReplay

  require Logger

  @supported_protocol_version "2025-11-25"
  @termination_timeout 5_000
  @default_max_request_ids 100_000
  @default_request_timeout_ms 60_000
  @default_max_pending_requests 128
  @default_max_active_requests 128
  @default_max_peer_tasks 128
  @default_max_peer_task_callbacks 128
  @default_max_queued_messages 1_024
  @default_max_queued_bytes 16 * 1_024 * 1_024
  @default_max_progress_per_second 20
  @default_max_inbound_progress_per_second 100
  @default_max_logs_per_second 100
  @logging_levels ~w(debug info notice warning error critical alert emergency)

  @doc "Starts the process owned by this module."
  def start_link(%{server_name: server_name, session_id: session_id} = opts) do
    GenServer.start_link(
      __MODULE__,
      {server_name, session_id, Map.get(opts, :idle_ttl_ms, :infinity),
       Map.fetch!(opts, :session_state_store),
       Map.get(opts, :max_request_ids, @default_max_request_ids), opts}
    )
  end

  @doc false
  def attach_sink(server_name, session_id, sink_pid, opts \\ [])
      when is_pid(sink_pid) and is_list(opts) do
    session_call(server_name, session_id, {:attach_sink, sink_pid, opts})
  end

  @doc false
  def detach_sink(server_name, session_id, sink_ref) when is_reference(sink_ref) do
    session_call(server_name, session_id, {:detach_sink, sink_ref})
  end

  @doc false
  def deliverable?(server_name, session_id) do
    case session_call(server_name, session_id, :deliverable?) do
      true -> true
      _other -> false
    end
  end

  @doc false
  def send_notification(server_name, session_id, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    envelope = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    session_call(server_name, session_id, {:send_notification, envelope, opts})
  end

  @doc false
  def send_envelope(server_name, session_id, envelope, opts \\ [])
      when is_map(envelope) and is_list(opts) do
    session_call(server_name, session_id, {:send_envelope, envelope, opts})
  end

  @doc false
  def request_peer(server_name, session_id, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:request_peer, method, params, opts}, :infinity)
    end
  end

  @doc false
  def resolve_peer_response(server_name, session_id, request_id, payload)
      when (is_binary(request_id) or is_integer(request_id)) and is_map(payload) do
    session_call(server_name, session_id, {:resolve_peer_response, request_id, payload})
  end

  @doc false
  def register_inbound_request(server_name, session_id, request_id, worker_pid, opts \\ [])
      when (is_binary(request_id) or is_integer(request_id)) and is_pid(worker_pid) and
             is_list(opts) do
    session_call(
      server_name,
      session_id,
      {:register_inbound_request, request_id, worker_pid, opts}
    )
  end

  @doc false
  def finish_inbound_request(server_name, session_id, request_id) do
    session_call(server_name, session_id, {:finish_inbound_request, request_id})
  end

  @doc false
  def receiver_task_started(server_name, session_id, task_id, request_id, progress_token)
      when is_binary(task_id) and task_id != "" and
             (is_binary(request_id) or is_integer(request_id)) do
    session_call(
      server_name,
      session_id,
      {:receiver_task_started, task_id, request_id, progress_token}
    )
  end

  @doc false
  def receiver_task_finished(server_name, session_id, task_id)
      when is_binary(task_id) and task_id != "" do
    session_call(server_name, session_id, {:receiver_task_finished, task_id})
  end

  @doc false
  def cancel_inbound_request(server_name, session_id, request_id, reason \\ nil) do
    session_call(server_name, session_id, {:cancel_inbound_request, request_id, reason})
  end

  @doc false
  def receive_peer_progress(server_name, session_id, params) when is_map(params) do
    session_call(server_name, session_id, {:receive_peer_progress, params})
  end

  @doc false
  def report_progress(server_name, session_id, request_id, params) when is_map(params) do
    session_call(server_name, session_id, {:report_progress, request_id, params})
  end

  @doc false
  def set_logging_level(server_name, session_id, level) do
    session_call(server_name, session_id, {:set_logging_level, to_string(level)})
  end

  @doc false
  def log(server_name, session_id, level, data, opts \\ []) when is_list(opts) do
    session_call(server_name, session_id, {:log, to_string(level), data, opts})
  end

  @doc false
  def cached_roots(server_name, session_id) do
    session_call(server_name, session_id, :cached_roots)
  end

  @doc false
  def cache_roots(server_name, session_id, roots) when is_list(roots) do
    session_call(server_name, session_id, {:cache_roots, roots})
  end

  @doc false
  def roots_changed(server_name, session_id) do
    session_call(server_name, session_id, :roots_changed)
  end

  @doc false
  def register_url_elicitation(server_name, session_id, %URLElicitation{} = elicitation) do
    session_call(server_name, session_id, {:register_url_elicitation, elicitation})
  end

  @doc false
  def url_elicitation(server_name, session_id, elicitation_id) do
    session_call(server_name, session_id, {:url_elicitation, elicitation_id})
  end

  @doc false
  def resolve_url_elicitation(server_name, session_id, elicitation_id, action, content \\ nil) do
    session_call(
      server_name,
      session_id,
      {:resolve_url_elicitation, elicitation_id, action, content}
    )
  end

  @doc false
  def complete_url_elicitation(
        server_name,
        session_id,
        elicitation_id,
        principal_fingerprint
      ) do
    session_call(
      server_name,
      session_id,
      {:complete_url_elicitation, elicitation_id, principal_fingerprint}
    )
  end

  @doc false
  def peer_task_fetch(server_name, session_id, task_id, opts) when is_list(opts) do
    request_peer(
      server_name,
      session_id,
      "tasks/get",
      %{"taskId" => task_id},
      opts
    )
  end

  @doc false
  def peer_task_result(server_name, session_id, task_id, opts) when is_list(opts) do
    request_peer(
      server_name,
      session_id,
      "tasks/result",
      %{"taskId" => task_id},
      opts
    )
  end

  @doc false
  def peer_task_cancel(server_name, session_id, task_id, opts) when is_list(opts) do
    request_peer(
      server_name,
      session_id,
      "tasks/cancel",
      %{"taskId" => task_id},
      opts
    )
  end

  @doc false
  def peer_task_wait(server_name, session_id, task_id, opts) when is_list(opts) do
    timeout_ms = positive_timeout(Keyword.get(opts, :timeout_ms, @default_request_timeout_ms))
    poll_interval = positive_timeout(Keyword.get(opts, :poll_interval_ms, 500))
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_peer_task_wait(server_name, session_id, task_id, opts, poll_interval, deadline)
  end

  @doc false
  def peer_task_on_status_change(server_name, session_id, task_id, callback)
      when is_function(callback, 1) do
    session_call(
      server_name,
      session_id,
      {:peer_task_on_status_change, task_id, callback}
    )
  end

  @doc false
  def receive_peer_task_status(server_name, session_id, params) when is_map(params) do
    session_call(server_name, session_id, {:receive_peer_task_status, params})
  end

  @doc "Reads a value from the backing store."
  def get(server_name, session_id, key, default \\ nil) do
    case Registry.lookup_session(server_name, session_id) do
      {:ok, pid} ->
        case GenServer.call(pid, {:get_state, key, default}) do
          {:ok, value} -> value
          :error -> default
          {:error, %Error{} = error} -> raise error
        end

      _other ->
        default
    end
  end

  @doc "Stores a value in the backing store."
  def put(server_name, session_id, key, value) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      pid
      |> GenServer.call({:put_state, key, value})
      |> unwrap_state_store_write!()
    end
  end

  @doc "Deletes a value from the backing store."
  def delete(server_name, session_id, key) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      pid
      |> GenServer.call({:delete_state, key})
      |> unwrap_state_store_write!()
    end
  end

  @doc false
  def close(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :terminate_session, @termination_timeout)
      catch
        :exit, reason -> {:error, state_store_error(:delete_session, {:session_exit, reason})}
      end

    case result do
      :ok ->
        await_termination(pid, monitor)

      {:error, %Error{}} = error ->
        Process.demonitor(monitor, [:flush])
        error
    end
  end

  @doc "Subscribes the session to updates for one concrete URI."
  def subscribe_resource(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:subscribe_resource, to_string(uri)})
    end
  end

  @doc "Removes one resource subscription from the session."
  def unsubscribe_resource(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:unsubscribe_resource, to_string(uri)})
    end
  end

  @doc "Returns whether the session is subscribed to the given concrete URI."
  def subscribed_to_resource?(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:subscribed_to_resource?, to_string(uri)})
    else
      _ -> false
    end
  end

  @doc "Lists resource subscriptions for the given session."
  def subscribed_resources(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :subscribed_resources)
    else
      _ -> []
    end
  end

  @doc "Stores negotiated client info for the given session."
  def set_client_info(server_name, session_id, client_info) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:set_client_info, client_info})
    end
  end

  @doc "Returns negotiated client info for the given session."
  def client_info(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :client_info)
    else
      _ -> nil
    end
  end

  @doc "Begins MCP initialization and records the negotiated client metadata."
  def begin_initialization(
        server_name,
        session_id,
        protocol_version,
        client_capabilities,
        client_info
      ) do
    begin_initialization(
      server_name,
      session_id,
      protocol_version,
      client_capabilities,
      client_info,
      :unbound,
      %{}
    )
  end

  @doc false
  def begin_initialization(
        server_name,
        session_id,
        protocol_version,
        client_capabilities,
        client_info,
        auth_identity
      ) do
    begin_initialization(
      server_name,
      session_id,
      protocol_version,
      client_capabilities,
      client_info,
      auth_identity,
      %{}
    )
  end

  @doc false
  def begin_initialization(
        server_name,
        session_id,
        protocol_version,
        client_capabilities,
        client_info,
        auth_identity,
        server_capabilities
      ) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(
        pid,
        {:begin_initialization, protocol_version, client_capabilities, client_info, auth_identity,
         server_capabilities}
      )
    end
  end

  @doc false
  def verify_identity(server_name, session_id, identity) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:verify_identity, identity})
    end
  end

  @doc false
  def claim_request_id(server_name, session_id, direction, request_id)
      when direction in [:client, :server] and
             (is_binary(request_id) or is_integer(request_id)) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:claim_request_id, direction, request_id})
    end
  end

  @doc "Marks a session initialized after the client initialization notification."
  def mark_initialized(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :mark_initialized)
    end
  end

  @doc "Returns the session lifecycle and negotiated initialization fields."
  def lifecycle(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :lifecycle)
    end
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({server_name, session_id, idle_ttl_ms, session_state_store, max_request_ids, opts}) do
    Process.flag(:trap_exit, true)
    generation = make_ref()

    case Registry.register_session(server_name, session_id, self(), generation) do
      :ok ->
        state =
          %{
            server_name: to_string(server_name),
            session_id: to_string(session_id),
            session_state_store: session_state_store,
            generation: generation,
            lifecycle_state: :new,
            protocol_version: nil,
            client_capabilities: nil,
            server_capabilities: nil,
            client_info: nil,
            auth_identity: :unbound,
            client_request_ids: MapSet.new(),
            server_request_ids: MapSet.new(),
            max_request_ids: max_request_ids,
            max_pending_requests:
              positive_option(opts, :max_pending_requests, @default_max_pending_requests),
            max_active_requests:
              positive_option(opts, :max_active_requests, @default_max_active_requests),
            max_peer_tasks: positive_option(opts, :max_peer_tasks, @default_max_peer_tasks),
            max_peer_task_callbacks:
              positive_option(
                opts,
                :max_peer_task_callbacks,
                @default_max_peer_task_callbacks
              ),
            max_queued_messages:
              positive_option(opts, :max_queued_messages, @default_max_queued_messages),
            max_queued_bytes: positive_option(opts, :max_queued_bytes, @default_max_queued_bytes),
            request_timeout_ms:
              positive_option(opts, :request_timeout_ms, @default_request_timeout_ms),
            max_progress_per_second:
              positive_option(
                opts,
                :max_progress_per_second,
                @default_max_progress_per_second
              ),
            runtime_quota: Map.fetch!(opts, :runtime_quota),
            task_supervisor: Map.get(opts, :task_supervisor),
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
            logging_level: "info",
            log_rate:
              RateWindow.new(
                limit: positive_option(opts, :max_logs_per_second, @default_max_logs_per_second)
              ),
            peer_progress_rate:
              RateWindow.new(
                limit:
                  positive_option(
                    opts,
                    :max_inbound_progress_per_second,
                    @default_max_inbound_progress_per_second
                  )
              ),
            redaction_opts: Map.get(opts, :redaction_opts, []),
            roots: nil,
            roots_generation: 0,
            peer_tasks: %{},
            peer_task_callbacks: %{},
            peer_task_callback_monitors: %{},
            url_elicitations: %{},
            replay:
              SSEReplay.new(
                max_events: Map.get(opts, :sse_replay_max_events, 256),
                max_stream_bytes: Map.get(opts, :sse_replay_max_stream_bytes, 4 * 1_024 * 1_024),
                max_total_bytes: Map.get(opts, :sse_replay_max_total_bytes, 64 * 1_024 * 1_024),
                ttl_ms: Map.get(opts, :sse_replay_ttl_ms, 5 * 60_000)
              ),
            resource_subscriptions: %{},
            inserted_at: System.system_time(:millisecond),
            last_touched_at: System.monotonic_time(:millisecond),
            idle_ttl_ms: idle_ttl_ms,
            timer_ref: nil,
            expiry_generation: nil
          }
          |> schedule_expiry()

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:attach_sink, sink_pid, opts}, _from, state) do
    kind = normalize_sink_kind(Keyword.get(opts, :kind, :get))
    last_event_id = Keyword.get(opts, :last_event_id)
    origin_request_id = Keyword.get(opts, :origin_request_id)
    {replay, stream_id, replayed, resume_status} = SSEReplay.open(state.replay, last_event_id)
    state = put_replay!(state, replay)
    emit_replay_reset(state, resume_status)

    case resume_status do
      status when status in [:fresh, :resumed] ->
        sink_ref = make_ref()
        monitor = Process.monitor(sink_pid)
        state = if kind == :get, do: replace_sink_kind(state, :get), else: state

        sink = %{
          ref: sink_ref,
          pid: sink_pid,
          monitor: monitor,
          kind: kind,
          stream_id: stream_id,
          origin_request_id: origin_request_id,
          inserted_at: System.monotonic_time(:millisecond)
        }

        state = %{
          state
          | sinks: Map.put(state.sinks, sink_ref, sink),
            sink_monitors: Map.put(state.sink_monitors, monitor, sink_ref)
        }

        state = claim_stream_owner(state, sink)

        Enum.each(replayed, fn
          %{kind: :cursor, id: event_id} ->
            send(sink_pid, {:fastest_mcp_session_cursor, sink_ref, event_id})

          %{id: event_id, envelope: envelope} ->
            send(sink_pid, {:fastest_mcp_session_message, sink_ref, event_id, envelope})
        end)

        state = prime_http_sink_cursor(state, sink)

        {state, queued_count} = flush_queued_to_sink(state, sink)

        reply = %{
          sink_ref: sink_ref,
          stream_id: stream_id,
          resumed?: resume_status == :resumed,
          replayed: length(replayed),
          queued: queued_count
        }

        {:reply, {:ok, reply}, touch(state)}

      {:error, reason} ->
        {:reply, {:error, {:last_event_id, reason}}, touch(state)}
    end
  end

  def handle_call({:detach_sink, sink_ref}, _from, state) do
    {:reply, :ok, state |> drop_sink(sink_ref) |> touch()}
  end

  def handle_call(:deliverable?, _from, state) do
    {:reply, map_size(state.stream_owners) > 0 and state.lifecycle_state == :initialized,
     touch(state)}
  end

  def handle_call({:send_notification, envelope, opts}, _from, state) do
    case emit_envelope(state, envelope, Keyword.put_new(opts, :queue, true)) do
      {:ok, state, delivery} -> {:reply, {:ok, delivery}, touch(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, touch(state)}
    end
  end

  def handle_call({:send_envelope, envelope, opts}, _from, state) do
    case emit_envelope(state, envelope, opts) do
      {:ok, state, delivery} -> {:reply, {:ok, delivery}, touch(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, touch(state)}
    end
  end

  def handle_call({:request_peer, method, params, opts}, from, state) do
    timeout_ms = positive_timeout(Keyword.get(opts, :timeout_ms, state.request_timeout_ms))
    sink_ref = Keyword.get(opts, :sink_ref)
    progress_token = Keyword.get(opts, :progress_token)

    cond do
      state.lifecycle_state != :initialized ->
        {:reply, {:error, :not_initialized}, touch(state)}

      not Protocol.client_supports_method?(state.client_capabilities, method, params) ->
        {:reply, {:error, :unsupported_capability}, touch(state)}

      map_size(state.pending_requests) >= state.max_pending_requests ->
        {:reply, {:error, :overloaded}, touch(state)}

      Map.has_key?(params, "task") and peer_task_capacity_reached?(state) ->
        {:reply, {:error, :overloaded}, touch(state)}

      not is_nil(progress_token) and Map.has_key?(state.peer_progress_tokens, progress_token) ->
        {:reply, {:error, :duplicate_progress_token}, touch(state)}

      not sink_available?(state, sink_ref) ->
        {:reply, {:error, :not_deliverable}, touch(state)}

      true ->
        case RuntimeQuota.claim(state.runtime_quota, self(), :pending_requests) do
          :ok ->
            case next_server_request_id(state) do
              {:ok, request_id, state} ->
                caller_pid = elem(from, 0)
                caller_monitor = Process.monitor(caller_pid)

                timer =
                  Process.send_after(self(), {:peer_request_timeout, request_id}, timeout_ms)

                params = put_request_progress_token(params, progress_token)

                envelope = %{
                  "jsonrpc" => "2.0",
                  "id" => request_id,
                  "method" => method,
                  "params" => params
                }

                pending = %{
                  from: from,
                  caller_pid: caller_pid,
                  caller_monitor: caller_monitor,
                  timer: timer,
                  method: method,
                  task_augmented: Map.has_key?(params, "task"),
                  peer_task_id: fetch(params, "taskId"),
                  peer_task_context: peer_task_context(method, params),
                  sink_ref: sink_ref,
                  progress_token: progress_token,
                  on_progress: Keyword.get(opts, :on_progress),
                  last_progress: nil,
                  progress_total: nil,
                  inserted_at: System.monotonic_time(:millisecond)
                }

                state = %{
                  state
                  | pending_requests: Map.put(state.pending_requests, request_id, pending),
                    pending_monitors: Map.put(state.pending_monitors, caller_monitor, request_id),
                    peer_progress_tokens:
                      maybe_put_progress_token(
                        state.peer_progress_tokens,
                        progress_token,
                        {:request, request_id}
                      )
                }

                case validate_outbound_peer_request(method, envelope, opts) do
                  :ok ->
                    case emit_envelope(state, envelope,
                           sink_ref: sink_ref,
                           origin_request_id: Keyword.get(opts, :origin_request_id),
                           request_id: request_id,
                           queue: false
                         ) do
                      {:ok, state, _delivery} ->
                        {:noreply, touch(state)}

                      {:error, reason, state} ->
                        {pending, state} = pop_pending(state, request_id)
                        cleanup_pending(pending)
                        {:reply, {:error, reason}, touch(state)}
                    end

                  {:error, reason} ->
                    {pending, state} = pop_pending(state, request_id)
                    cleanup_pending(pending)
                    {:reply, {:error, reason}, touch(state)}
                end

              {:error, :overloaded, state} ->
                :ok = RuntimeQuota.release(state.runtime_quota, self(), :pending_requests)
                {:reply, {:error, request_id_capacity_error()}, touch(state)}
            end

          {:error, :overloaded} ->
            {:reply, {:error, :overloaded}, touch(state)}
        end
    end
  end

  def handle_call({:resolve_peer_response, request_id, payload}, _from, state) do
    case Map.fetch(state.pending_requests, request_id) do
      :error ->
        {:reply, :ignored, touch(state)}

      {:ok, pending} ->
        {^pending, state} = pop_pending(state, request_id)
        cleanup_pending(pending)
        state = put_replay!(state, SSEReplay.acknowledge(state.replay, request_id))

        response = normalize_peer_response(pending, payload, state)
        GenServer.reply(pending.from, response)

        state = maybe_track_peer_task_result(state, pending, payload, response)
        {:reply, :ok, touch(state)}
    end
  end

  def handle_call({:register_inbound_request, request_id, worker_pid, opts}, _from, state) do
    progress_token = Keyword.get(opts, :progress_token)

    cond do
      map_size(state.active_requests) >= state.max_active_requests ->
        {:reply, {:error, :overloaded}, touch(state)}

      Map.has_key?(state.active_requests, request_id) ->
        {:reply, {:error, :duplicate}, touch(state)}

      not is_nil(progress_token) and Map.has_key?(state.progress_tokens, progress_token) ->
        {:reply, {:error, :duplicate_progress_token}, touch(state)}

      true ->
        case RuntimeQuota.claim(state.runtime_quota, self(), :active_requests) do
          :ok ->
            monitor = Process.monitor(worker_pid)

            active = %{
              worker_pid: worker_pid,
              monitor: monitor,
              method: Keyword.get(opts, :method),
              cancellable?: Keyword.get(opts, :cancellable, true),
              task_augmented?: Keyword.get(opts, :task_augmented, false),
              progress_token: progress_token,
              last_progress: nil,
              progress_total: nil,
              progress_rate:
                RateWindow.new(
                  limit:
                    Keyword.get(opts, :max_progress_per_second, state.max_progress_per_second)
                ),
              cancelled?: false
            }

            state = %{
              state
              | active_requests: Map.put(state.active_requests, request_id, active),
                active_monitors: Map.put(state.active_monitors, monitor, request_id),
                progress_tokens:
                  maybe_put_progress_token(state.progress_tokens, progress_token, request_id)
            }

            {:reply, :ok, touch(state)}

          {:error, :overloaded} ->
            {:reply, {:error, :overloaded}, touch(state)}
        end
    end
  end

  def handle_call({:finish_inbound_request, request_id}, _from, state) do
    case pop_active(state, request_id) do
      {nil, state} -> {:reply, :unknown, touch(state)}
      {%{cancelled?: true}, state} -> {:reply, :suppress, touch(state)}
      {_active, state} -> {:reply, :deliver, touch(state)}
    end
  end

  def handle_call(
        {:receiver_task_started, task_id, request_id, progress_token},
        _from,
        state
      ) do
    cond do
      Map.has_key?(state.receiver_tasks, task_id) ->
        {:reply, {:error, :already_started}, touch(state)}

      not is_nil(progress_token) and
          progress_token_owned_by_other_request?(state, progress_token, request_id) ->
        {:reply, {:error, :duplicate_progress_token}, touch(state)}

      true ->
        active = Map.get(state.active_requests, request_id)

        task = %{
          request_id: request_id,
          progress_token: progress_token,
          last_progress: active && active.last_progress,
          progress_total: active && active.progress_total,
          progress_rate:
            (active && active.progress_rate) ||
              RateWindow.new(limit: state.max_progress_per_second),
          started_at: System.monotonic_time(:millisecond)
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
            progress_tokens:
              maybe_put_progress_token(state.progress_tokens, progress_token, request_id)
        }

        {:reply, :ok, touch(state)}
    end
  end

  def handle_call({:receiver_task_finished, task_id}, _from, state) do
    case pop_receiver_task(state, task_id) do
      {nil, state} -> {:reply, :unknown, touch(state)}
      {_task, state} -> {:reply, :ok, touch(state)}
    end
  end

  def handle_call({:cancel_inbound_request, request_id, _reason}, _from, state) do
    case Map.get(state.active_requests, request_id) do
      nil ->
        {:reply, :ignored, touch(state)}

      %{method: "initialize"} ->
        {:reply, :ignored, touch(state)}

      %{task_augmented?: true} ->
        {:reply, :ignored, touch(state)}

      %{cancellable?: false} ->
        {:reply, :ignored, touch(state)}

      active ->
        Process.exit(active.worker_pid, :shutdown)
        active = %{active | cancelled?: true}

        {:reply, :ok,
         %{touch(state) | active_requests: Map.put(state.active_requests, request_id, active)}}
    end
  end

  def handle_call({:receive_peer_progress, params}, _from, state) do
    token = fetch(params, "progressToken")

    case Map.get(state.peer_progress_tokens, token) do
      nil ->
        {:reply, :ignored, touch(state)}

      {:request, request_id} ->
        receive_pending_peer_progress(state, request_id, params)

      {:task, task_id} ->
        receive_task_peer_progress(state, task_id, params)

      request_id ->
        receive_pending_peer_progress(state, request_id, params)
    end
  end

  def handle_call({:report_progress, request_id, params}, _from, state) do
    case Map.get(state.active_requests, request_id) do
      nil ->
        report_receiver_task_progress(state, request_id, params)

      active ->
        progress = fetch(params, "progress")
        total = ProtocolProgress.total(params)

        with {:ok, progress_total} <-
               ProtocolProgress.validate_update(
                 progress,
                 active.last_progress,
                 total,
                 active.progress_total
               ),
             {:ok, rate} <- allow_rate(active.progress_rate) do
          token = active.progress_token
          envelope_params = Map.put(params, "progressToken", token)

          case emit_envelope(
                 state,
                 %{
                   "jsonrpc" => "2.0",
                   "method" => "notifications/progress",
                   "params" => envelope_params
                 },
                 queue: false
               ) do
            {:ok, state, _delivery} ->
              active = %{
                active
                | last_progress: progress,
                  progress_total: progress_total,
                  progress_rate: rate
              }

              state = %{
                state
                | active_requests: Map.put(state.active_requests, request_id, active)
              }

              {:reply, :ok, touch(state)}

            {:error, reason, state} ->
              {:reply, {:error, reason}, touch(state)}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, touch(state)}
        end
    end
  end

  def handle_call({:set_logging_level, level}, _from, state) do
    if level in @logging_levels do
      {:reply, :ok, %{touch(state) | logging_level: level}}
    else
      {:reply, {:error, :invalid_level}, touch(state)}
    end
  end

  def handle_call({:log, level, data, opts}, _from, state) do
    cond do
      level not in @logging_levels ->
        {:reply, {:error, :invalid_level}, touch(state)}

      logging_level_index(level) < logging_level_index(state.logging_level) ->
        {:reply, :filtered, touch(state)}

      true ->
        case RateWindow.allow(state.log_rate) do
          {:error, :rate_limited, rate} ->
            {:reply, {:error, :rate_limited}, %{touch(state) | log_rate: rate}}

          {:ok, rate} ->
            params =
              %{
                "level" => level,
                "data" => Redactor.redact(data, Keyword.merge(state.redaction_opts, opts))
              }
              |> maybe_put("logger", Keyword.get(opts, :logger))

            envelope = %{
              "jsonrpc" => "2.0",
              "method" => "notifications/message",
              "params" => params
            }

            state = %{state | log_rate: rate}

            case emit_envelope(state, envelope, queue: true) do
              {:ok, state, _delivery} -> {:reply, :ok, touch(state)}
              {:error, reason, state} -> {:reply, {:error, reason}, touch(state)}
            end
        end
    end
  end

  def handle_call({:peer_task_on_status_change, task_id, callback}, from, state) do
    cond do
      peer_task_callback_count(state) >= state.max_peer_task_callbacks ->
        {:reply, {:error, :overloaded}, touch(state)}

      not Map.has_key?(state.peer_tasks, task_id) ->
        {:reply, {:error, :not_found}, touch(state)}

      terminal_peer_task?(Map.get(state.peer_tasks, task_id)) ->
        {:reply, {:error, :task_terminal}, touch(state)}

      true ->
        owner_pid = elem(from, 0)
        callback_ref = make_ref()
        monitor = Process.monitor(owner_pid)

        callback_entry = %{
          callback: callback,
          owner_pid: owner_pid,
          monitor: monitor
        }

        callbacks =
          Map.update(
            state.peer_task_callbacks,
            task_id,
            %{callback_ref => callback_entry},
            &Map.put(&1, callback_ref, callback_entry)
          )

        callback_monitors =
          Map.put(state.peer_task_callback_monitors, monitor, {task_id, callback_ref})

        {:reply, :ok,
         %{
           touch(state)
           | peer_task_callbacks: callbacks,
             peer_task_callback_monitors: callback_monitors
         }}
    end
  end

  def handle_call({:receive_peer_task_status, params}, _from, state) do
    case fetch(params, "taskId") do
      task_id when is_binary(task_id) and task_id != "" ->
        existing = Map.get(state.peer_tasks, task_id)

        cond do
          terminal_peer_task?(existing) ->
            {:reply, :ignored, touch(state)}

          is_nil(existing) ->
            {:reply, :ignored, touch(state)}

          true ->
            peer_task_context = existing.context

            Enum.each(Map.get(state.peer_task_callbacks, task_id, %{}), fn {
                                                                             _callback_ref,
                                                                             entry
                                                                           } ->
              run_callback(state, entry.callback, params)
            end)

            state =
              track_peer_task(
                state,
                params,
                "notifications/tasks/status",
                peer_task_context
              )

            {:reply, :ok, touch(state)}
        end

      _other ->
        {:reply, {:error, :invalid_task_status}, touch(state)}
    end
  end

  def handle_call(:cached_roots, _from, state), do: {:reply, state.roots, touch(state)}

  def handle_call({:cache_roots, roots}, _from, state) do
    case normalize_roots(roots) do
      {:ok, roots} ->
        {:reply, {:ok, roots},
         %{touch(state) | roots: roots, roots_generation: state.roots_generation + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, touch(state)}
    end
  end

  def handle_call(:roots_changed, _from, state) do
    state = %{state | roots: nil, roots_generation: state.roots_generation + 1}
    maybe_refresh_roots(state)
    {:reply, :ok, touch(state)}
  end

  def handle_call({:register_url_elicitation, elicitation}, _from, state) do
    id = elicitation.elicitation_id

    if Map.has_key?(state.url_elicitations, id) do
      {:reply, {:error, :already_exists}, touch(state)}
    else
      case Registry.register_url_elicitation(
             state.server_name,
             id,
             state.session_id,
             self()
           ) do
        :ok ->
          {:reply, :ok,
           %{touch(state) | url_elicitations: Map.put(state.url_elicitations, id, elicitation)}}

        {:error, :already_exists} ->
          {:reply, {:error, :already_exists}, touch(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, touch(state)}
      end
    end
  end

  def handle_call({:url_elicitation, id}, _from, state) do
    case Map.fetch(state.url_elicitations, id) do
      {:ok, elicitation} -> {:reply, {:ok, elicitation}, touch(state)}
      :error -> {:reply, {:error, :not_found}, touch(state)}
    end
  end

  def handle_call({:resolve_url_elicitation, id, action, content}, _from, state) do
    case Map.fetch(state.url_elicitations, id) do
      :error ->
        {:reply, {:error, :not_found}, touch(state)}

      {:ok, elicitation} ->
        case URLElicitation.respond(elicitation, action, content) do
          {:ok, updated} ->
            state =
              if updated.action in [:decline, :cancel] do
                drop_url_elicitation(state, id)
              else
                put_url_elicitation(state, updated)
              end

            {:reply, {:ok, updated}, touch(state)}

          {:error, :expired} ->
            {:reply, {:error, :expired}, state |> drop_url_elicitation(id) |> touch()}

          {:error, reason} ->
            {:reply, {:error, reason}, touch(state)}
        end
    end
  end

  def handle_call({:complete_url_elicitation, id, principal_fingerprint}, _from, state) do
    case Map.fetch(state.url_elicitations, id) do
      :error ->
        {:reply, {:error, :not_found}, touch(state)}

      {:ok, elicitation} ->
        case URLElicitation.complete(
               elicitation,
               state.session_id,
               principal_fingerprint
             ) do
          {:ok, updated} ->
            state = put_url_elicitation(state, updated)
            {:ok, params} = URLElicitation.completion_params(updated)

            case emit_envelope(
                   state,
                   %{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/elicitation/complete",
                     "params" => params
                   },
                   queue: true
                 ) do
              {:ok, state, _delivery} -> {:reply, {:ok, updated}, touch(state)}
              {:error, reason, state} -> {:reply, {:error, reason}, touch(state)}
            end

          {:error, :expired} ->
            {:reply, {:error, :expired}, state |> drop_url_elicitation(id) |> touch()}

          {:error, reason} ->
            {:reply, {:error, normalize_url_completion_error(reason)}, touch(state)}
        end
    end
  end

  def handle_call({:get_state, key, _default}, _from, state) do
    reply =
      state_store_call(:get, fn ->
        SessionStateStore.get(state.session_state_store, state.session_id, key)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call({:put_state, key, value}, _from, state) do
    reply =
      state_store_call(:put, fn ->
        SessionStateStore.put(state.session_state_store, state.session_id, key, value)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call({:delete_state, key}, _from, state) do
    reply =
      state_store_call(:delete, fn ->
        SessionStateStore.delete(state.session_state_store, state.session_id, key)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call(:terminate_session, _from, state) do
    case delete_session_state(state) do
      :ok ->
        {:stop, :normal, :ok, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, touch(state)}
    end
  end

  def handle_call({:subscribe_resource, uri}, _from, state) do
    next_state = touch(state)

    {:reply, :ok,
     %{
       next_state
       | resource_subscriptions: Map.put(next_state.resource_subscriptions, uri, true)
     }}
  end

  def handle_call({:unsubscribe_resource, uri}, _from, state) do
    next_state = touch(state)

    {:reply, :ok,
     %{next_state | resource_subscriptions: Map.delete(next_state.resource_subscriptions, uri)}}
  end

  def handle_call({:subscribed_to_resource?, uri}, _from, state) do
    {:reply, Map.has_key?(state.resource_subscriptions, uri), touch(state)}
  end

  def handle_call(:subscribed_resources, _from, state) do
    {:reply, state.resource_subscriptions |> Map.keys() |> Enum.sort(), touch(state)}
  end

  def handle_call({:set_client_info, client_info}, _from, state) do
    normalized =
      client_info
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    {:reply, :ok, %{touch(state) | client_info: normalized}}
  end

  def handle_call(:client_info, _from, state) do
    {:reply, state.client_info, touch(state)}
  end

  def handle_call(
        {:begin_initialization, _requested_protocol_version, client_capabilities, client_info,
         auth_identity, server_capabilities},
        _from,
        state
      ) do
    cond do
      state.lifecycle_state != :new ->
        {:reply, {:error, {:invalid_transition, state.lifecycle_state}}, touch(state)}

      true ->
        client_capabilities = normalize_client_capabilities(client_capabilities)
        server_capabilities = Protocol.normalize_capabilities(server_capabilities)

        next_state = %{
          touch(state)
          | lifecycle_state: :initializing,
            protocol_version: @supported_protocol_version,
            client_capabilities: client_capabilities,
            server_capabilities: server_capabilities,
            client_info: client_info,
            auth_identity: auth_identity
        }

        {:reply, :ok, next_state}
    end
  end

  def handle_call(:mark_initialized, _from, %{lifecycle_state: :initializing} = state) do
    {:reply, :ok, %{touch(state) | lifecycle_state: :initialized}}
  end

  def handle_call(:mark_initialized, _from, state) do
    {:reply, {:error, {:invalid_transition, state.lifecycle_state}}, touch(state)}
  end

  def handle_call({:verify_identity, identity}, _from, %{auth_identity: :unbound} = state) do
    {:reply, :ok, %{touch(state) | auth_identity: identity}}
  end

  def handle_call({:verify_identity, identity}, _from, %{auth_identity: identity} = state) do
    {:reply, :ok, touch(state)}
  end

  def handle_call({:verify_identity, _identity}, _from, state) do
    {:reply, {:error, :identity_mismatch}, touch(state)}
  end

  def handle_call({:claim_request_id, direction, request_id}, _from, state) do
    key = request_id_set_key(direction)
    request_ids = Map.fetch!(state, key)

    cond do
      MapSet.member?(request_ids, request_id) ->
        {:reply, {:error, :duplicate}, touch(state)}

      MapSet.size(request_ids) >= state.max_request_ids ->
        {:reply, {:error, :overloaded}, touch(state)}

      true ->
        {:reply, :ok, state |> Map.put(key, MapSet.put(request_ids, request_id)) |> touch()}
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

    {:reply, {:ok, lifecycle}, touch(state)}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:peer_request_timeout, request_id}, state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:noreply, state}

      pending ->
        {_pending, state} = pop_pending(state, request_id)
        cleanup_pending(pending, cancel_timer: false)

        state =
          emit_cancellation(
            state,
            request_id,
            "server request timed out",
            pending.sink_ref
          )

        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, touch(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      sink_ref = Map.get(state.sink_monitors, monitor) ->
        {:noreply, state |> drop_sink(sink_ref, false) |> touch()}

      request_id = Map.get(state.pending_monitors, monitor) ->
        case Map.get(state.pending_requests, request_id) do
          %{caller_pid: ^pid} = pending ->
            {_pending, state} = pop_pending(state, request_id)
            cleanup_pending(pending, monitor: false)

            state =
              emit_cancellation(
                state,
                request_id,
                "server request caller terminated",
                pending.sink_ref
              )

            {:noreply, touch(state)}

          _other ->
            {:noreply, state}
        end

      request_id = Map.get(state.active_monitors, monitor) ->
        case Map.get(state.active_requests, request_id) do
          %{worker_pid: ^pid} ->
            {_active, state} = pop_active(state, request_id, false)
            {:noreply, touch(state)}

          _other ->
            {:noreply, state}
        end

      callback_key = Map.get(state.peer_task_callback_monitors, monitor) ->
        {task_id, callback_ref} = callback_key

        {:noreply,
         state
         |> drop_peer_task_callback(task_id, callback_ref, false)
         |> touch()}

      true ->
        Logger.debug("session ignored unknown process DOWN: #{inspect({pid, reason})}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:expire_if_idle, generation},
        %{idle_ttl_ms: idle_ttl_ms, expiry_generation: generation} = state
      )
      when idle_ttl_ms != :infinity do
    case delete_session_state(state) do
      :ok ->
        {:stop, :normal, %{state | timer_ref: nil, expiry_generation: nil}}

      {:error, %Error{} = error} ->
        Logger.error(
          "session #{inspect(state.session_id)} idle cleanup failed: #{Exception.message(error)}"
        )

        {:noreply, schedule_expiry(%{state | timer_ref: nil, expiry_generation: nil})}
    end
  end

  def handle_info({:expire_if_idle, _stale_generation}, state), do: {:noreply, state}

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    Enum.each(state.pending_requests, fn {_request_id, pending} ->
      cleanup_pending(pending)
      GenServer.reply(pending.from, {:error, :session_terminated})
    end)

    Enum.each(state.active_requests, fn {_request_id, active} ->
      Process.demonitor(active.monitor, [:flush])

      if Process.alive?(active.worker_pid) do
        Process.exit(active.worker_pid, :shutdown)
      end
    end)

    Enum.each(state.sinks, fn {_sink_ref, sink} ->
      Process.demonitor(sink.monitor, [:flush])
      send(sink.pid, {:fastest_mcp_session_terminated, sink.ref})
    end)

    Enum.each(state.peer_task_callback_monitors, fn {monitor, _callback_key} ->
      Process.demonitor(monitor, [:flush])
    end)

    Enum.each(state.url_elicitations, fn {elicitation_id, _elicitation} ->
      Registry.unregister_url_elicitation(
        state.server_name,
        elicitation_id,
        state.session_id,
        self()
      )
    end)

    Registry.unregister_session(
      state.server_name,
      state.session_id,
      self(),
      state.generation
    )

    :ok
  end

  defp delete_session_state(state) do
    state_store_call(:delete_session, fn ->
      SessionStateStore.delete_session(state.session_state_store, state.session_id)
    end)
  end

  defp state_store_call(operation, fun) do
    operation
    |> normalize_state_store_result(fun.())
  rescue
    error -> {:error, state_store_error(operation, error)}
  catch
    kind, reason -> {:error, state_store_error(operation, {kind, reason})}
  end

  defp normalize_state_store_result(:get, {:ok, _value} = result), do: result
  defp normalize_state_store_result(:get, :error), do: :error
  defp normalize_state_store_result(operation, :ok) when operation != :get, do: :ok

  defp normalize_state_store_result(operation, {:error, reason}),
    do: {:error, state_store_error(operation, reason)}

  defp normalize_state_store_result(operation, result),
    do: {:error, state_store_error(operation, {:invalid_result, result})}

  defp state_store_error(_operation, %Error{} = error), do: error

  defp state_store_error(operation, reason) do
    %Error{
      code: :internal_error,
      message: "session state storage #{operation} failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp unwrap_state_store_write!(:ok), do: :ok
  defp unwrap_state_store_write!({:error, %Error{} = error}), do: raise(error)

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

  defp touch(state) do
    state
    |> Map.put(:last_touched_at, System.monotonic_time(:millisecond))
    |> schedule_expiry()
  end

  defp schedule_expiry(state) when map_size(state.sinks) > 0,
    do: cancel_expiry(state)

  defp schedule_expiry(state) when map_size(state.pending_requests) > 0,
    do: cancel_expiry(state)

  defp schedule_expiry(state) when map_size(state.active_requests) > 0,
    do: cancel_expiry(state)

  defp schedule_expiry(state) when map_size(state.receiver_tasks) > 0,
    do: cancel_expiry(state)

  defp schedule_expiry(state) do
    if active_peer_tasks?(state.peer_tasks) do
      cancel_expiry(state)
    else
      schedule_unheld_expiry(state)
    end
  end

  defp schedule_unheld_expiry(%{idle_ttl_ms: :infinity} = state),
    do: %{state | timer_ref: nil, expiry_generation: nil}

  defp schedule_unheld_expiry(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

    expiry_generation = make_ref()

    timer_ref =
      Process.send_after(self(), {:expire_if_idle, expiry_generation}, state.idle_ttl_ms)

    %{state | timer_ref: timer_ref, expiry_generation: expiry_generation}
  end

  defp cancel_expiry(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)
    %{state | timer_ref: nil, expiry_generation: nil}
  end

  defp session_call(server_name, session_id, message) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      safe_session_call(pid, message)
    end
  end

  defp safe_session_call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
    :exit, {:normal, _call} -> {:error, :not_found}
    :exit, {:shutdown, _call} -> {:error, :not_found}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :not_found}
  end

  defp normalize_sink_kind(kind) when kind in [:post, :get, :stdio], do: kind

  defp normalize_sink_kind(other) do
    raise ArgumentError, "sink kind must be :post, :get, or :stdio, got: #{inspect(other)}"
  end

  defp replace_sink_kind(state, kind) do
    state.sinks
    |> Enum.filter(fn {_ref, sink} -> sink.kind == kind end)
    |> Enum.reduce(state, fn {ref, sink}, current ->
      send(sink.pid, {:fastest_mcp_session_replaced, ref})
      drop_sink(current, ref)
    end)
  end

  defp claim_stream_owner(state, sink) do
    case Map.get(state.stream_owners, sink.stream_id) do
      nil ->
        :ok

      previous_ref ->
        case Map.get(state.sinks, previous_ref) do
          nil -> :ok
          previous -> send(previous.pid, {:fastest_mcp_session_replaced, previous.ref})
        end
    end

    %{state | stream_owners: Map.put(state.stream_owners, sink.stream_id, sink.ref)}
  end

  defp drop_sink(state, sink_ref, demonitor? \\ true) do
    case Map.pop(state.sinks, sink_ref) do
      {nil, _sinks} ->
        state

      {sink, sinks} ->
        if demonitor?, do: Process.demonitor(sink.monitor, [:flush])

        stream_owners =
          case Map.get(state.stream_owners, sink.stream_id) do
            ^sink_ref -> Map.delete(state.stream_owners, sink.stream_id)
            _other -> state.stream_owners
          end

        %{
          state
          | sinks: sinks,
            sink_monitors: Map.delete(state.sink_monitors, sink.monitor),
            stream_owners: stream_owners
        }
    end
  end

  defp sink_available?(state, nil), do: map_size(state.stream_owners) > 0
  defp sink_available?(state, sink_ref), do: Map.has_key?(state.sinks, sink_ref)

  defp emit_envelope(state, envelope, opts) do
    case select_sink(state, opts) do
      nil ->
        if Keyword.get(opts, :queue, false) do
          queue_envelope(state, envelope, opts)
        else
          {:error, :not_deliverable, state}
        end

      sink ->
        case record_for_sink(state, sink, envelope, opts) do
          {:ok, state, event_id} ->
            delivery_sink = deliver_to_stream_owner(state, sink, event_id, envelope)

            {:ok, state,
             %{
               sink_ref: sink.ref,
               delivery_sink_ref: delivery_sink && delivery_sink.ref,
               event_id: event_id
             }}

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp deliver_to_stream_owner(state, sink, event_id, envelope) do
    with owner_ref when is_reference(owner_ref) <- Map.get(state.stream_owners, sink.stream_id),
         owner when is_map(owner) <- Map.get(state.sinks, owner_ref) do
      send(owner.pid, {:fastest_mcp_session_message, owner.ref, event_id, envelope})
      owner
    else
      _other -> nil
    end
  end

  defp select_sink(state, opts) do
    requested = Keyword.get(opts, :sink_ref)
    origin_request_id = Keyword.get(opts, :origin_request_id)

    cond do
      not is_nil(requested) ->
        Map.get(state.sinks, requested)

      not is_nil(origin_request_id) ->
        Enum.find_value(state.sinks, fn {_ref, sink} ->
          if sink.origin_request_id == origin_request_id, do: sink
        end) || fallback_sink(state)

      true ->
        fallback_sink(state)
    end
  end

  defp fallback_sink(state) do
    state.stream_owners
    |> Map.values()
    |> Enum.map(&Map.get(state.sinks, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn sink ->
      {sink_priority(sink.kind), -sink.inserted_at}
    end)
    |> List.first()
  end

  defp sink_priority(:stdio), do: 0
  defp sink_priority(:get), do: 1
  defp sink_priority(:post), do: 2

  defp prime_http_sink_cursor(state, %{kind: :stdio}), do: state

  defp prime_http_sink_cursor(state, sink) do
    {replay, event_id, retained?} = SSEReplay.record_cursor(state.replay, sink.stream_id)

    if retained? and
         RuntimeQuota.resize(state.runtime_quota, self(), :sse_replay_bytes, replay.total_bytes) ==
           :ok do
      send(sink.pid, {:fastest_mcp_session_cursor, sink.ref, event_id})
      %{state | replay: replay}
    else
      state
    end
  end

  defp record_for_sink(state, %{kind: kind}, _envelope, _opts) when kind == :stdio,
    do: {:ok, state, nil}

  defp record_for_sink(state, sink, envelope, opts) do
    {replay, event_id, retained?} =
      SSEReplay.record(state.replay, sink.stream_id, envelope,
        request_id: Keyword.get(opts, :request_id)
      )

    resize_result =
      RuntimeQuota.resize(
        state.runtime_quota,
        self(),
        :sse_replay_bytes,
        replay.total_bytes
      )

    case {retained?, resize_result} do
      {true, :ok} ->
        {:ok, %{state | replay: replay}, event_id}

      {false, :ok} ->
        {:error, :sse_replay_unavailable, %{state | replay: replay}}

      {_retained?, {:error, :overloaded}} ->
        # Re-record against the committed state so the rejected event advances
        # the stream cursor without consuming replay quota. Authenticated event
        # IDs include a random nonce, so this untransmitted fallback ID is not
        # expected to equal the rejected candidate ID.
        {fallback, _fallback_event_id, false} =
          SSEReplay.record(state.replay, sink.stream_id, envelope,
            request_id: Keyword.get(opts, :request_id),
            retain?: false
          )

        {:error, :sse_replay_unavailable, put_replay!(state, fallback)}
    end
  end

  defp put_replay!(state, replay) do
    :ok =
      RuntimeQuota.resize(
        state.runtime_quota,
        self(),
        :sse_replay_bytes,
        replay.total_bytes
      )

    %{state | replay: replay}
  end

  defp emit_replay_reset(state, {status, reason}) when status in [:fresh, :error] do
    :telemetry.execute(
      [:fastest_mcp, :sse, :replay_reset],
      %{count: 1},
      %{reason: reason, server_name: state.server_name, session_id: state.session_id}
    )

    :ok
  end

  defp emit_replay_reset(_state, _status), do: :ok

  defp queue_envelope(state, envelope, opts) do
    bytes = envelope |> JSON.encode!() |> byte_size()

    cond do
      :queue.len(state.queued_messages) >= state.max_queued_messages ->
        {:error, :queue_overloaded, state}

      state.queued_bytes + bytes > state.max_queued_bytes ->
        {:error, :queue_overloaded, state}

      true ->
        queued = %{
          envelope: envelope,
          bytes: bytes,
          request_id: Keyword.get(opts, :request_id)
        }

        {:ok,
         %{
           state
           | queued_messages: :queue.in(queued, state.queued_messages),
             queued_bytes: state.queued_bytes + bytes
         }, %{queued: true}}
    end
  end

  defp flush_queued_to_sink(state, sink) do
    queued = :queue.to_list(state.queued_messages)

    state = %{
      state
      | queued_messages: :queue.new(),
        queued_bytes: 0
    }

    {state, delivered_count} =
      Enum.reduce(queued, {state, 0}, fn item, {current, delivered_count} ->
        case record_for_sink(current, sink, item.envelope, request_id: item.request_id) do
          {:ok, current, event_id} ->
            send(
              sink.pid,
              {:fastest_mcp_session_message, sink.ref, event_id, item.envelope}
            )

            {current, delivered_count + 1}

          {:error, :sse_replay_unavailable, current} ->
            {current, delivered_count}
        end
      end)

    {state, delivered_count}
  end

  defp next_server_request_id(state) do
    if MapSet.size(state.server_request_ids) >= state.max_request_ids do
      {:error, :overloaded, state}
    else
      request_id = random_request_id()

      if MapSet.member?(state.server_request_ids, request_id) do
        next_server_request_id(state)
      else
        {:ok, request_id,
         %{state | server_request_ids: MapSet.put(state.server_request_ids, request_id)}}
      end
    end
  end

  defp random_request_id do
    "srv-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp request_id_capacity_error do
    %Error{
      code: :overloaded,
      message: "JSON-RPC request id capacity has been reached",
      details: %{resource: :request_ids, retry_after_seconds: 1},
      terminate_session_after_delivery: true
    }
  end

  defp pop_pending(state, request_id) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, pending_requests} ->
        {nil, %{state | pending_requests: pending_requests}}

      {pending, pending_requests} ->
        :ok = RuntimeQuota.release(state.runtime_quota, self(), :pending_requests)

        state = %{
          state
          | pending_requests: pending_requests,
            pending_monitors: Map.delete(state.pending_monitors, pending.caller_monitor),
            peer_progress_tokens:
              maybe_delete_progress_token(
                state.peer_progress_tokens,
                pending.progress_token,
                {:request, request_id}
              )
        }

        {pending, state}
    end
  end

  defp cleanup_pending(pending, opts \\ [])
  defp cleanup_pending(nil, _opts), do: :ok

  defp cleanup_pending(pending, opts) do
    if Keyword.get(opts, :cancel_timer, true),
      do: Process.cancel_timer(pending.timer, async: true, info: false)

    if Keyword.get(opts, :monitor, true),
      do: Process.demonitor(pending.caller_monitor, [:flush])

    :ok
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
      if Schema.protocol_supported?(
           @supported_protocol_version,
           :client_to_server,
           kind,
           method
         ) do
        Schema.validate_protocol(
          @supported_protocol_version,
          :client_to_server,
          kind,
          method,
          payload
        )
      else
        Schema.validate_protocol(
          @supported_protocol_version,
          :client_to_server,
          :response,
          payload
        )
      end

    case validation do
      {:ok, ^payload} -> :ok
      {:error, %FastestMCP.Schema.Error{} = error} -> {:error, {method, error}}
      {:error, %Error{} = error} -> {:error, error}
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

  defp validate_outbound_peer_request(method, envelope, opts) do
    related_task_id = Keyword.get(opts, :protocol_related_task_id)

    allowed_reserved =
      if is_binary(related_task_id), do: ["io.modelcontextprotocol/related-task"], else: []

    with :ok <- validate_protocol_related_task(envelope, related_task_id),
         :ok <- validate_protocol_meta(envelope, :application, allowed_reserved) do
      if Schema.protocol_supported?(
           @supported_protocol_version,
           :server_to_client,
           :request,
           method
         ) do
        case Schema.validate_protocol(
               @supported_protocol_version,
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
              [Map.get(related, "taskId", Map.get(related, :taskId)) | ids]

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
    envelope = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => request_id, "reason" => reason}
    }

    case emit_envelope(state, envelope, sink_ref: sink_ref, queue: false) do
      {:ok, state, _delivery} -> state
      {:error, _reason, state} -> state
    end
  end

  defp pop_active(state, request_id, demonitor? \\ true) do
    case Map.pop(state.active_requests, request_id) do
      {nil, active_requests} ->
        {nil, %{state | active_requests: active_requests}}

      {active, active_requests} ->
        :ok = RuntimeQuota.release(state.runtime_quota, self(), :active_requests)

        if demonitor?, do: Process.demonitor(active.monitor, [:flush])

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
                  maybe_delete_progress_token(
                    state.progress_tokens,
                    active.progress_token,
                    request_id
                  )
              )
        }

        {active, state}
    end
  end

  defp maybe_put_progress_token(tokens, nil, _request_id), do: tokens
  defp maybe_put_progress_token(tokens, token, request_id), do: Map.put(tokens, token, request_id)

  defp put_request_progress_token(params, nil), do: params

  defp put_request_progress_token(params, token) do
    case Map.get(params, "_meta", %{}) do
      meta when is_map(meta) -> Map.put(params, "_meta", Map.put(meta, "progressToken", token))
      _invalid_meta -> params
    end
  end

  defp maybe_delete_progress_token(tokens, nil, _request_id), do: tokens

  defp maybe_delete_progress_token(tokens, token, request_id) do
    if Map.get(tokens, token) == request_id, do: Map.delete(tokens, token), else: tokens
  end

  defp progress_token_owned_by_other_request?(state, token, request_id) do
    case Map.get(state.progress_tokens, token) do
      nil -> false
      ^request_id -> false
      _other_request_id -> true
    end
  end

  defp receive_pending_peer_progress(state, request_id, params) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:reply, :ignored, touch(state)}

      pending ->
        progress = fetch(params, "progress")

        with {:ok, progress_total} <-
               ProtocolProgress.validate_update(
                 progress,
                 pending.last_progress,
                 ProtocolProgress.total(params),
                 pending.progress_total
               ),
             {:ok, rate} <- allow_rate(state.peer_progress_rate) do
          pending = %{
            pending
            | last_progress: progress,
              progress_total: progress_total
          }

          state = %{
            state
            | pending_requests: Map.put(state.pending_requests, request_id, pending),
              peer_progress_rate: rate
          }

          run_callback(state, pending.on_progress, params)
          {:reply, :ok, touch(state)}
        else
          {:error, :rate_limited} ->
            {:reply, {:error, :rate_limited}, touch(state)}

          {:error, _reason} ->
            {:reply, :ignored, touch(state)}
        end
    end
  end

  defp receive_task_peer_progress(state, task_id, params) do
    case Map.get(state.peer_tasks, task_id) do
      nil ->
        {:reply, :ignored, touch(state)}

      peer_task ->
        context = peer_task.context
        progress = fetch(params, "progress")

        with {:ok, progress_total} <-
               ProtocolProgress.validate_update(
                 progress,
                 Map.get(context, :last_progress),
                 ProtocolProgress.total(params),
                 Map.get(context, :progress_total)
               ),
             {:ok, rate} <- allow_rate(state.peer_progress_rate) do
          context = %{
            context
            | last_progress: progress,
              progress_total: progress_total
          }

          peer_task = %{peer_task | context: context}

          state = %{
            state
            | peer_tasks: Map.put(state.peer_tasks, task_id, peer_task),
              peer_progress_rate: rate
          }

          run_callback(state, Map.get(context, :on_progress), params)
          {:reply, :ok, touch(state)}
        else
          {:error, :rate_limited} ->
            {:reply, {:error, :rate_limited}, touch(state)}

          {:error, _reason} ->
            {:reply, :ignored, touch(state)}
        end
    end
  end

  defp report_receiver_task_progress(state, request_id, params) do
    case receiver_task_for_request(state, request_id) do
      nil ->
        {:reply, {:error, :unknown_request}, touch(state)}

      {task_id, task} ->
        progress = fetch(params, "progress")
        total = ProtocolProgress.total(params)

        with {:ok, progress_total} <-
               ProtocolProgress.validate_update(
                 progress,
                 task.last_progress,
                 total,
                 task.progress_total
               ),
             {:ok, rate} <- allow_rate(task.progress_rate) do
          envelope_params = Map.put(params, "progressToken", task.progress_token)

          case emit_envelope(
                 state,
                 %{
                   "jsonrpc" => "2.0",
                   "method" => "notifications/progress",
                   "params" => envelope_params
                 },
                 queue: false
               ) do
            {:ok, state, _delivery} ->
              task = %{
                task
                | last_progress: progress,
                  progress_total: progress_total,
                  progress_rate: rate
              }

              state = %{state | receiver_tasks: Map.put(state.receiver_tasks, task_id, task)}
              {:reply, :ok, touch(state)}

            {:error, reason, state} ->
              {:reply, {:error, reason}, touch(state)}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, touch(state)}
        end
    end
  end

  defp receiver_task_for_request(state, request_id) do
    state.receiver_task_requests
    |> Map.get(request_id, MapSet.new())
    |> Enum.find_value(fn task_id ->
      case Map.fetch(state.receiver_tasks, task_id) do
        {:ok, task} -> {task_id, task}
        :error -> nil
      end
    end)
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
            maybe_delete_progress_token(
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

  defp allow_rate(rate) do
    case RateWindow.allow(rate) do
      {:ok, next} -> {:ok, next}
      {:error, :rate_limited, _next} -> {:error, :rate_limited}
    end
  end

  defp run_callback(_state, nil, _params), do: :ok

  defp run_callback(%{task_supervisor: supervisor}, callback, params)
       when is_pid(supervisor) and is_function(callback, 1) do
    _ = Task.Supervisor.start_child(supervisor, fn -> callback.(params) end)
    :ok
  end

  defp run_callback(_state, _callback, _params), do: :ok

  defp logging_level_index(level), do: Enum.find_index(@logging_levels, &(&1 == level)) || 0

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
    :ok =
      Registry.unregister_url_elicitation(
        state.server_name,
        elicitation_id,
        state.session_id,
        self()
      )

    %{state | url_elicitations: Map.delete(state.url_elicitations, elicitation_id)}
  end

  defp normalize_url_completion_error(:already_completed), do: :already_completed
  defp normalize_url_completion_error(reason), do: reason

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
    task_id = fetch(task, "taskId")

    state
    |> put_peer_task(task, source_method, context)
    |> maybe_release_terminal_peer_url(task_id, task)
    |> maybe_finalize_terminal_peer_task(task_id, task)
  end

  defp put_peer_task(state, task, source_method, context) do
    case fetch(task, "taskId") do
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
              context: context,
              updated_at: System.monotonic_time(:millisecond)
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
    token =
      state.peer_tasks
      |> Map.get(task_id, %{})
      |> Map.get(:context, %{})
      |> Map.get(:progress_token)

    %{
      state
      | peer_progress_tokens:
          maybe_delete_progress_token(state.peer_progress_tokens, token, {:task, task_id})
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
    if fetch(task, "status") in ["failed", "cancelled", :failed, :cancelled] do
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

  defp peer_url_elicitation_id(state, task_id) do
    state.peer_tasks
    |> Map.get(task_id, %{})
    |> Map.get(:context, %{})
    |> Map.get(:url_elicitation_id)
  end

  defp active_peer_tasks?(peer_tasks) do
    Enum.any?(peer_tasks, fn {_task_id, peer_task} ->
      status = fetch(peer_task.task, "status")
      status not in ["completed", "failed", "cancelled", :completed, :failed, :cancelled]
    end)
  end

  defp terminal_peer_task?(nil), do: false

  defp terminal_peer_task?(%{task: task}), do: terminal_task_status?(task)

  defp peer_task_capacity_reached?(state) do
    reservations =
      Enum.count(state.pending_requests, fn {_request_id, pending} -> pending.task_augmented end)

    map_size(state.peer_tasks) + reservations >= state.max_peer_tasks
  end

  defp peer_task_callback_count(state), do: map_size(state.peer_task_callback_monitors)

  defp maybe_finalize_terminal_peer_task(state, task_id, task) do
    if terminal_task_status?(task) do
      state
      |> release_peer_task_progress(task_id)
      |> drop_peer_task_callbacks(task_id)
    else
      state
    end
  end

  defp terminal_task_status?(task) do
    fetch(task, "status") in [
      "completed",
      "failed",
      "cancelled",
      :completed,
      :failed,
      :cancelled
    ]
  end

  defp drop_peer_task_callbacks(state, task_id) do
    case Map.pop(state.peer_task_callbacks, task_id) do
      {nil, _callbacks} ->
        state

      {callbacks, remaining_callbacks} ->
        callback_monitors =
          Enum.reduce(callbacks, state.peer_task_callback_monitors, fn {
                                                                         _callback_ref,
                                                                         callback_entry
                                                                       },
                                                                       monitors ->
            Process.demonitor(callback_entry.monitor, [:flush])
            Map.delete(monitors, callback_entry.monitor)
          end)

        %{
          state
          | peer_task_callbacks: remaining_callbacks,
            peer_task_callback_monitors: callback_monitors
        }
    end
  end

  defp drop_peer_task_callback(state, task_id, callback_ref, demonitor?) do
    case Map.get(state.peer_task_callbacks, task_id) do
      nil ->
        state

      callbacks ->
        case Map.pop(callbacks, callback_ref) do
          {nil, _callbacks} ->
            state

          {callback_entry, remaining_callbacks} ->
            if demonitor?, do: Process.demonitor(callback_entry.monitor, [:flush])

            peer_task_callbacks =
              if map_size(remaining_callbacks) == 0 do
                Map.delete(state.peer_task_callbacks, task_id)
              else
                Map.put(state.peer_task_callbacks, task_id, remaining_callbacks)
              end

            %{
              state
              | peer_task_callbacks: peer_task_callbacks,
                peer_task_callback_monitors:
                  Map.delete(state.peer_task_callback_monitors, callback_entry.monitor)
            }
        end
    end
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

  defp positive_option(opts, key, default) do
    case Map.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp positive_timeout(value) when is_integer(value) and value > 0, do: value

  defp positive_timeout(other),
    do: raise(ArgumentError, "timeout must be positive, got: #{inspect(other)}")

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_id_set_key(:client), do: :client_request_ids
  defp request_id_set_key(:server), do: :server_request_ids

  # MCP 2025-11-25 retains the pre-mode elicitation capability spelling:
  # `elicitation: {}` is semantically equivalent to `elicitation.form: {}`.
  # Store effective capabilities so every callback gate sees one canonical form.
  defp normalize_client_capabilities(%{"elicitation" => elicitation} = capabilities)
       when is_map(elicitation) and map_size(elicitation) == 0 do
    put_in(capabilities, ["elicitation"], %{"form" => %{}})
  end

  defp normalize_client_capabilities(capabilities), do: capabilities
end
