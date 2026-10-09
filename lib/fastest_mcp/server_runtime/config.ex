defmodule FastestMCP.ServerRuntime.Config do
  @moduledoc false
  # Runtime options of one server, validated once when it starts.

  alias FastestMCP.Options

  @session_keys [
    :max_request_ids,
    :max_pending_requests,
    :max_active_requests,
    :max_peer_tasks,
    :max_peer_task_callbacks,
    :max_queued_messages,
    :max_queued_bytes,
    :request_timeout_ms,
    :max_progress_per_second,
    :max_inbound_progress_per_second,
    :max_logs_per_second,
    :redaction_opts,
    :sse_replay_max_events,
    :sse_replay_max_stream_bytes,
    :sse_replay_max_total_bytes,
    :sse_replay_ttl_ms
  ]

  @options [
    max_sessions: {:limit, 10_000},
    session_idle_ttl: {:limit, 15 * 60_000},
    strict_request_ids: {:boolean, false},
    max_concurrent_calls: {:limit, :infinity},
    max_background_tasks: {:limit, :infinity},
    max_runtime_pending_requests: {:pos_integer, 10_000},
    max_runtime_active_requests: {:pos_integer, 10_000},
    sse_replay_max_total_bytes: {:pos_integer, 64 * 1_024 * 1_024},
    terminated_session_ttl: {:limit, 15 * 60_000},
    max_event_subscribers_per_server: {:limit, 1_024},
    max_event_subscriber_queue_len: {:non_neg_limit, 100},
    task_backend: {:module_with_opts, {FastestMCP.TaskBackend.Memory, []}},
    session_state_store: {:module_with_opts, {FastestMCP.SessionStateStore.Memory, []}},
    # Per-session limits; unset ones keep the `FastestMCP.Session` defaults.
    max_request_ids: {:pos_integer, nil},
    max_pending_requests: {:pos_integer, nil},
    max_active_requests: {:pos_integer, nil},
    max_peer_tasks: {:pos_integer, nil},
    max_peer_task_callbacks: {:pos_integer, nil},
    max_queued_messages: {:pos_integer, nil},
    max_queued_bytes: {:pos_integer, nil},
    request_timeout_ms: {:pos_integer, nil},
    max_progress_per_second: {:pos_integer, nil},
    max_inbound_progress_per_second: {:pos_integer, nil},
    max_logs_per_second: {:pos_integer, nil},
    redaction_opts: {:keyword, nil},
    sse_replay_max_events: {:pos_integer, nil},
    sse_replay_max_stream_bytes: {:pos_integer, nil},
    sse_replay_ttl_ms: {:pos_integer, nil}
  ]

  def new!(opts), do: Options.validate!(opts, @options)

  def session_opts(config) do
    config
    |> Map.take(@session_keys)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:idle_ttl_ms, config.session_idle_ttl)
  end
end
