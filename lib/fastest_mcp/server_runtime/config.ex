defmodule FastestMCP.ServerRuntime.Config do
  @moduledoc false
  # Runtime options of one server, validated in the caller when it starts. The
  # validated config, not the options, goes into the start arguments of the
  # server's processes, so a configured `signing_secret` stays in a
  # `FastestMCP.Secret`, which inspect output leaves out. Start arguments that
  # hold the options themselves, such as a server module's child spec, hold
  # them with the secret wrapped by `protect/1`, as `new!/1` takes it too.

  alias FastestMCP.Options
  alias FastestMCP.Secret

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
    # Signs list cursors and the request state of multi-round requests.
    signing_secret: {:any, nil},
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

  defstruct Enum.map(@options, fn {key, {_rule, default}} -> {key, default} end)

  def new!(%__MODULE__{} = config), do: config

  def new!(opts) do
    config = struct!(__MODULE__, Options.validate!(opts, @options))
    %{config | signing_secret: secret!(config.signing_secret)}
  end

  # Runtime options, a keyword list or a map, with the signing secret wrapped.
  def protect(opts) when is_list(opts), do: Enum.map(opts, &protect_option/1)
  def protect(opts) when is_map(opts), do: Map.new(opts, &protect_option/1)
  def protect(opts), do: opts

  defp protect_option({:signing_secret, secret}) when is_binary(secret),
    do: {:signing_secret, %Secret{value: secret}}

  defp protect_option(option), do: option

  # The configured secret, or a random one for each start of the server.
  def signing_secret(%__MODULE__{signing_secret: nil}),
    do: %Secret{value: :crypto.strong_rand_bytes(32)}

  def signing_secret(%__MODULE__{signing_secret: secret}), do: secret

  def session_opts(config) do
    config
    |> Map.take(@session_keys)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:idle_ttl_ms, config.session_idle_ttl)
  end

  # The error leaves the value out: it may be the secret, nearly.
  defp secret!(nil), do: nil
  defp secret!(%Secret{value: secret}), do: secret!(secret)

  defp secret!(secret) when is_binary(secret) and byte_size(secret) >= 32,
    do: %Secret{value: secret}

  defp secret!(_secret),
    do: raise(ArgumentError, "signing_secret must be a binary of at least 32 bytes")
end
