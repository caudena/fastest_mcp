defmodule FastestMCP.Client.TransportSnapshot do
  @moduledoc false
  # What workers, `Client.Wire`, `Client.HTTP` and `Client.Auth` read from a
  # connection: transport configuration and the negotiated session, never
  # pending requests, task registries, or waiters. Only sends the connection
  # makes itself carry its `phase` (see `HTTP.send_notification/3`).

  alias FastestMCP.Client.Connection.State

  defstruct [
    :client_pid,
    :transport,
    :session_id,
    :session_generation,
    :phase,
    :protocol_preference,
    :selected_protocol_version,
    :server_identity,
    :client_info,
    :extensions,
    :roots_supported?,
    :sampling_handler,
    :sampling_tools,
    :sampling_context,
    :elicitation_handler,
    :url_elicitation_handler,
    :auth_input,
    :log_level,
    :legacy_stdio_auth_metadata?,
    :oauth,
    :timeout_ms,
    :max_response_bytes,
    :max_sse_event_bytes,
    :sse_reconnect
  ]

  @type t :: %__MODULE__{}

  def new(%State{config: config, lifecycle: lifecycle} = state, own? \\ false) do
    %__MODULE__{
      client_pid: self(),
      transport: state.transport,
      session_id: lifecycle.session_id,
      session_generation: lifecycle.session_generation,
      phase: if(own?, do: lifecycle.phase),
      protocol_preference: config.protocol_version,
      selected_protocol_version: lifecycle.protocol_version,
      server_identity: lifecycle.server_identity,
      client_info: config.client_info,
      extensions: config.extensions,
      roots_supported?: is_list(config.roots),
      sampling_handler: config.sampling_handler,
      sampling_tools: config.sampling_tools,
      sampling_context: config.sampling_context,
      elicitation_handler: config.elicitation_handler,
      url_elicitation_handler: config.url_elicitation_handler,
      auth_input: config.auth_input,
      # A log handler alone asks for `info` and above, as a 2025-11-25 session
      # receives by default.
      log_level: config.log_level || if(config.log_handler, do: "info"),
      legacy_stdio_auth_metadata?: config.legacy_stdio_auth_metadata,
      oauth: state.oauth,
      timeout_ms: config.timeout_ms,
      max_response_bytes: config.max_response_bytes,
      max_sse_event_bytes: config.max_sse_event_bytes,
      sse_reconnect: config.sse_reconnect
    }
  end
end
