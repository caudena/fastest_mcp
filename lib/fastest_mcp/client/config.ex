defmodule FastestMCP.Client.Config do
  @moduledoc false
  # Validated connection options, built by `FastestMCP.Client.Options.validate!/2`
  # in the caller before the client process starts. `log_level` is set by
  # `FastestMCP.Client.set_log_level/3`.

  defstruct [
    :name,
    :transport,
    :protocol_version,
    :auto_initialize,
    :session_stream,
    :init_timeout_ms,
    :timeout_ms,
    :max_in_flight,
    :max_mrtr_rounds,
    :max_response_bytes,
    :max_sse_event_bytes,
    :max_callback_request_ids,
    :sse_reconnect,
    :stdio_restart,
    :response_cache,
    :roots,
    :extensions,
    :schema_options,
    :client_info,
    :sampling_tools,
    :sampling_context,
    :sampling_handler,
    :elicitation_handler,
    :url_elicitation_handler,
    :elicitation_complete_handler,
    :log_handler,
    :log_level,
    :progress_handler,
    :notification_handler,
    :auth_input,
    :oauth,
    :max_auth_attempts,
    :legacy_stdio_auth_metadata
  ]

  @type t :: %__MODULE__{}
end
