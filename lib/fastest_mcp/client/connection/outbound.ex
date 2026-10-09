defmodule FastestMCP.Client.Connection.Outbound do
  @moduledoc false
  # The connection's in-flight client→server requests, keyed by local
  # reference and indexed by JSON-RPC id. `finish/3` is the one teardown: it
  # stops a request's timer, HTTP exchange, worker and monitors, then replies.

  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.Connection.TaskRegistry
  alias FastestMCP.Client.HTTP
  alias FastestMCP.Client.ResponseCache
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Trace
  alias FastestMCP.Client.Transport
  alias FastestMCP.Client.TransportSnapshot
  alias FastestMCP.Client.Wire
  alias FastestMCP.Client.Workers
  alias FastestMCP.Deadline
  alias FastestMCP.Error

  defstruct requests: %{}, ids: %{}, next_id: 1

  defmodule Request do
    @moduledoc false
    # A modern `subscriptions/listen` also carries
    # `subscription: %{acknowledged?: boolean, filter: term, attempt: integer}`.
    @enforce_keys [:ref, :id, :spec, :reply_to, :owner_ref, :timeout_ms, :session_generation]
    defstruct [
      :ref,
      :id,
      :spec,
      :reply_to,
      :owner_ref,
      :timeout_ms,
      :session_generation,
      :timer,
      :worker,
      :worker_ref,
      :http_ref,
      :progress_token,
      :progress,
      :progress_total,
      :cache_key,
      :subscription,
      task_augmented?: false
    ]
  end

  ## Index

  def fetch(%State{outbound: outbound}, ref), do: Map.fetch(outbound.requests, ref)

  def by_id(%State{outbound: outbound}, id) do
    with {:ok, ref} <- Map.fetch(outbound.ids, id), do: Map.fetch(outbound.requests, ref)
  end

  def put(%State{outbound: outbound} = state, %Request{ref: ref} = request) do
    ids =
      case outbound.requests do
        %{^ref => previous} -> Map.delete(outbound.ids, previous.id)
        _new -> outbound.ids
      end

    ids = if is_nil(request.id), do: ids, else: Map.put(ids, request.id, ref)

    %{
      state
      | outbound: %{outbound | requests: Map.put(outbound.requests, ref, request), ids: ids}
    }
  end

  def update(state, ref, fun) do
    case fetch(state, ref) do
      {:ok, request} -> put(state, fun.(request))
      :error -> state
    end
  end

  ## Teardown

  # Releases everything a request holds without replying to its caller.
  def take(%State{outbound: outbound} = state, ref) do
    case Map.pop(outbound.requests, ref) do
      {nil, _requests} ->
        {nil, state}

      {request, requests} ->
        cancel_timer(request.timer)
        HTTP.cancel(request.http_ref)
        if request.worker, do: Process.exit(request.worker, :kill)
        outbound = %{outbound | requests: requests, ids: Map.delete(outbound.ids, request.id)}

        state =
          %{state | outbound: outbound}
          |> State.demonitor(request.worker_ref)
          |> State.demonitor(request.owner_ref)

        {request, state}
    end
  end

  def finish(state, ref, reply) do
    case take(state, ref) do
      {nil, state} ->
        state

      {request, state} ->
        reply(request, reply)
        state
    end
  end

  # A successful response also updates what its result implies: the session
  # id, the response cache, a created task's progress route and owner, and the
  # initialize result.
  def complete(state, ref, {:ok, value, session_id, hint}) do
    case fetch(state, ref) do
      {:ok, request} ->
        state =
          if session_id && request.session_generation == state.lifecycle.session_generation,
            do: put_in(state.lifecycle.session_id, session_id),
            else: state

        state = finish(state, ref, {:ok, value})

        state =
          update_in(
            state.catalog.responses,
            &ResponseCache.store(&1, request.cache_key, value, hint)
          )

        state = update_in(state.tasks, &TaskRegistry.retain_progress(&1, request, value))

        state =
          if request.spec.owns_task?,
            do: TaskRegistry.own(state, owner(request.reply_to), value),
            else: state

        case request.spec.normalizer do
          {:initialize, _version} -> put_in(state.lifecycle.initialize_result, value)
          _normalizer -> state
        end

      :error ->
        state
    end
  end

  def complete(state, ref, error), do: finish(state, ref, error)

  def finish_all(state, reply),
    do: Enum.reduce(Map.keys(state.outbound.requests), state, &finish(&2, &1, reply))

  def reply(%Request{reply_to: {:sync, from}}, reply), do: GenServer.reply(from, reply)

  def reply(%Request{reply_to: {:async, owner}} = request, reply) do
    finish_trace(request, reply)
    send(owner, {:fastest_mcp_client_response, request.ref, reply})
    :ok
  end

  # An asynchronous request ends the span it owns when it replies.
  def finish_trace(%Request{spec: %Spec{end_trace?: true, trace: trace, method: method}}, reply) do
    Trace.mark_tool_error(reply, trace, method)
    Trace.finish(trace, reply)
  end

  def finish_trace(_request, _reply), do: :ok

  def cancel_timer(nil), do: :ok

  def cancel_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  ## Start

  # Validates and sends one request; its reply comes through `finish/3`. A
  # cache hit replies at once.
  def start(%State{} = state, %Spec{} = spec, reply_to) do
    view = TransportSnapshot.new(state)
    spec = %{spec | protocol_version: Wire.request_version(view, spec.method)}
    Trace.annotate_request(spec, view)
    id = Integer.to_string(state.outbound.next_id)

    with :ok <- check_budget(owner(reply_to), spec.deadline),
         :ok <- Lifecycle.check_request(state.lifecycle, spec.method, spec.normalizer),
         :ok <- Auth.check_transport(state.transport, spec.auth),
         :ok <- check_connected(state.transport),
         :ok <- check_capacity(state),
         :ok <- check_supported(state, spec.method),
         :ok <- check_progress_token(state, Spec.progress_token(spec)),
         spec = initialize_normalizer(spec),
         {:ok, envelope} <- envelope(spec, id, view),
         key = cache_key(state, spec, reply_to, view),
         {:miss, state} <- cached(state, key, spec.cache) do
      send_request(state, spec, reply_to, id, envelope, key)
    else
      {:hit, result, state} ->
        Trace.annotate_request(spec, view, %{"fastestmcp.cache.hit" => true})
        {:cached, result, state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  def check_budget(owner, deadline) do
    cond do
      node(owner) == node() and not Process.alive?(owner) ->
        {:error, %Error{code: :cancelled, message: "client request owner exited"}}

      Deadline.remaining(deadline || :infinity) == 0 ->
        {:error, %Error{code: :timeout, message: "client request deadline elapsed"}}

      true ->
        :ok
    end
  end

  defp check_connected(%{type: type} = transport) when type in [:stdio, :in_process] do
    if Transport.connected?(transport),
      do: :ok,
      else:
        {:error,
         %Error{
           code: :internal_error,
           message: "#{Transport.name(type)} client transport is closed"
         }}
  end

  defp check_connected(_transport), do: :ok

  defp check_capacity(%{config: %{max_in_flight: :infinity}}), do: :ok

  defp check_capacity(state) do
    if map_size(state.outbound.requests) < state.config.max_in_flight,
      do: :ok,
      else:
        {:error,
         %Error{
           code: :overloaded,
           message: "client is at max in-flight capacity",
           details: %{resource: :client_requests, retry_after_seconds: 1}
         }}
  end

  defp check_supported(state, method) do
    if Lifecycle.supports?(state.lifecycle, state.config.extensions, method),
      do: :ok,
      else:
        {:error,
         %Error{
           code: :method_not_found,
           message: "server did not advertise support for #{method}",
           details: %{required_capability: FastestMCP.Protocol.required_server_capability(method)}
         }}
  end

  defp check_progress_token(_state, nil), do: :ok

  defp check_progress_token(state, token) do
    in_use? =
      Enum.any?(state.outbound.requests, fn {_ref, request} -> request.progress_token == token end) or
        Enum.any?(state.tasks, fn {_task_id, entry} -> entry.progress_token == token end)

    if in_use?,
      do:
        {:error,
         %Error{
           code: :invalid_params,
           message: "progress tokens must be unique among active requests and tasks"
         }},
      else: :ok
  end

  defp initialize_normalizer(%Spec{method: "initialize"} = spec),
    do: %{spec | normalizer: {:initialize, legacy()}}

  defp initialize_normalizer(spec), do: spec

  defp cache_key(state, spec, {:sync, _from}, view) do
    lifecycle = state.lifecycle

    if lifecycle.phase == :initialized and is_modern(lifecycle.protocol_version) do
      ResponseCache.key(state.catalog.responses, spec, {
        lifecycle.protocol_version,
        view.client_info,
        Wire.modern_capabilities(view),
        Lifecycle.server_capabilities(lifecycle),
        view.extensions,
        state.config.roots,
        lifecycle.auth_generation,
        lifecycle.server_identity
      })
    end
  end

  defp cache_key(_state, _spec, _async, _view), do: nil

  defp cached(state, key, mode) do
    case ResponseCache.fetch(state.catalog.responses, key, mode) do
      {:hit, result, cache} -> {:hit, result, put_in(state.catalog.responses, cache)}
      {:miss, cache} -> {:miss, put_in(state.catalog.responses, cache)}
    end
  end

  defp send_request(state, spec, reply_to, id, envelope, key) do
    ref = make_ref()
    {owner_ref, next} = State.monitor(state, owner(reply_to), {:owner, ref})
    timeout_ms = Deadline.remaining(spec.deadline)

    request = %Request{
      ref: ref,
      id: id,
      spec: spec,
      reply_to: reply_to,
      owner_ref: owner_ref,
      timeout_ms: timeout_ms,
      session_generation: state.lifecycle.session_generation,
      timer:
        if(timeout_ms != :infinity,
          do: Process.send_after(self(), {:request_timeout, ref}, timeout_ms)
        ),
      progress_token: Spec.progress_token(spec),
      cache_key: key,
      task_augmented?: Wire.task_augmented?(spec.params),
      subscription:
        if(spec.method == "subscriptions/listen" and is_modern(spec.protocol_version),
          do: %{acknowledged?: false, filter: nil, attempt: 0}
        )
    }

    next =
      next
      |> next_id()
      |> put(request)
      |> Map.update!(:lifecycle, &Lifecycle.put_client_capabilities(&1, envelope))

    case state.transport.type do
      :streamable_http ->
        {:ok, request, start_worker(next, request, envelope)}

      _connected ->
        case Transport.write(state.transport, envelope) do
          :ok ->
            {:ok, request, next}

          {:error, error} ->
            Process.demonitor(owner_ref, [:flush])
            cancel_timer(request.timer)
            {:error, error, state}
        end
    end
  end

  defp envelope(spec, id, view),
    do: Wire.request(%{spec | params: Trace.inject(spec.params, spec.trace_context)}, id, view)

  defp next_id(state), do: update_in(state.outbound.next_id, &(&1 + 1))

  defp owner({:sync, {pid, _tag}}), do: pid
  defp owner({:async, pid}), do: pid

  defp start_worker(state, %Request{ref: ref, spec: spec} = request, envelope) do
    view = TransportSnapshot.new(state)

    pid =
      Workers.start!(state.worker_supervisor, fn ->
        send(view.client_pid, {:http, ref, {:done, HTTP.request(view, ref, envelope, spec)}})
      end)

    {worker_ref, state} = State.monitor(state, pid, {:worker, ref})
    put(state, %{request | worker: pid, worker_ref: worker_ref})
  end

  ## Cancellation

  def cancel(state, ref, reason) do
    case fetch(state, ref) do
      :error ->
        {:error, %Error{code: :bad_request, message: "client request is no longer in flight"}}

      {:ok, %Request{spec: %Spec{method: "initialize"}}} ->
        {:error,
         %Error{code: :bad_request, message: "the initialize request cannot be cancelled"}}

      {:ok, request} ->
        {:ok, cancelled(state, request, reason)}
    end
  end

  # Tells the server, then fails the request locally.
  def cancelled(state, %Request{} = request, reason) do
    notify_cancelled(state, request, reason)

    finish(
      state,
      request.ref,
      {:error, %Error{code: :cancelled, message: "#{request.spec.method} was cancelled"}}
    )
  end

  def timed_out(state, ref) do
    case fetch(state, ref) do
      {:ok, %Request{} = request} ->
        notify_cancelled(state, request, "request timed out")

        finish(
          state,
          ref,
          {:error,
           %Error{
             code: :timeout,
             message: "#{request.spec.method} timed out",
             details: %{timeout_ms: request.timeout_ms}
           }}
        )

      :error ->
        state
    end
  end

  def notify_cancelled(_state, %Request{spec: %Spec{method: "initialize"}}, _reason), do: :ok

  def notify_cancelled(%{transport: %{type: :stdio, port: port}}, _request, _reason)
      when not is_port(port),
      do: :ok

  def notify_cancelled(state, %Request{} = request, reason) do
    params = maybe_put(%{"requestId" => request.id}, "reason", reason)
    opts = [timeout_ms: min(state.config.timeout_ms, 1000)]

    case state.transport.type do
      # Modern HTTP cancellation is closing the request-scoped response.
      :streamable_http when is_modern(state.lifecycle.protocol_version) ->
        :ok

      :streamable_http ->
        view = TransportSnapshot.new(state)

        Task.Supervisor.start_child(state.worker_supervisor, fn ->
          notify(view, "notifications/cancelled", params, opts)
        end)

        :ok

      _connected ->
        notify(TransportSnapshot.new(state, true), "notifications/cancelled", params, opts)
    end
  end

  # Sends one notification over the transport the snapshot describes.
  def notify(view, method, params, opts) do
    with :ok <- Auth.check_transport(view.transport, opts),
         {:ok, message} <- Wire.notification(method, params, view, opts) do
      case view.transport.type do
        :streamable_http -> HTTP.send_notification(message, view, opts)
        _connected -> Transport.write(view.transport, message)
      end
    end
  end

  ## Modern subscriptions

  # A terminated HTTP subscription stream is reopened under a new id after
  # the server's retry delay, within the SSE reconnect budget.
  def detach(state, %Request{subscription: %{attempt: attempt}} = request, error, retry_delay) do
    HTTP.cancel(request.http_ref)
    state = State.demonitor(state, request.worker_ref)

    request = %{
      request
      | worker: nil,
        worker_ref: nil,
        http_ref: nil,
        subscription: %{request.subscription | acknowledged?: false, filter: nil}
    }

    state = put(state, request)
    max_attempts = state.config.sse_reconnect.max_attempts

    if attempt < max_attempts and is_integer(retry_delay) do
      Process.send_after(self(), {:reconnect_subscription, request.ref}, retry_delay)
      put(state, put_in(request.subscription.attempt, attempt + 1))
    else
      details =
        Map.merge(error.details || %{}, %{
          reconnect_attempts: attempt,
          reconnect_exhausted: attempt >= max_attempts
        })

      finish(state, request.ref, {:error, %{error | details: details}})
    end
  end

  # Re-sends a modern subscription under a new JSON-RPC id.
  def reopen(state, %Request{} = request) do
    id = Integer.to_string(state.outbound.next_id)

    case envelope(request.spec, id, TransportSnapshot.new(state)) do
      {:ok, envelope} ->
        request = %{
          request
          | id: id,
            subscription: %{request.subscription | acknowledged?: false, filter: nil}
        }

        case state.transport.type do
          :streamable_http ->
            state |> next_id() |> put(request) |> start_worker(request, envelope)

          _connected ->
            case Transport.write(state.transport, envelope) do
              :ok -> state |> next_id() |> put(request)
              # The child may exit between Port.open/2 and the first command;
              # the listener stays detached for the next restart attempt.
              {:error, _error} -> state
            end
        end

      {:error, error} ->
        finish(state, request.ref, {:error, error})
    end
  end
end
