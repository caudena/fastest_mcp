defmodule FastestMCP.Client.State.Pending do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:in_flight, :worker_refs, :request_owner_refs]
end

defmodule FastestMCP.Client.State.Callbacks do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :callback_tasks,
    :callback_task_refs,
    :callback_result_waiters,
    :callback_requests,
    :callback_worker_refs,
    :callback_request_ids,
    :pending_url_elicitations
  ]
end

defmodule FastestMCP.Client.State.Stdio do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :pending_stdio_buffer,
    :pending_stdio_ref,
    :pending_stdio_refs,
    :stdio_restart,
    :stdio_restart_attempt,
    :stdio_restart_timer_ref,
    :stdio_restart_token
  ]
end

defmodule FastestMCP.Client.State.Catalog do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:tool_catalog, :tool_catalog_ready?, :tool_catalog_load, :response_cache]
end

defmodule FastestMCP.Client.State.Tasks do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:task_registry]
end

defmodule FastestMCP.Client.State.Lifecycle do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :lifecycle_state,
    :initialization_owner_ref,
    :discovery_attempt,
    :readiness_waiters,
    :readiness_owner_refs,
    :recovery,
    :session_generation,
    :auth_generation,
    :disconnecting?
  ]
end

defmodule FastestMCP.Client.State do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :pending,
    :callbacks,
    :stdio,
    :catalog,
    :tasks,
    :lifecycle,
    :client_pid,
    :transport,
    :session_id,
    :initialize_result,
    :discovery_result,
    :protocol_preference,
    :selected_protocol_version,
    :extensions,
    :max_mrtr_rounds,
    :advertised_client_capabilities,
    :schema_options,
    :server_identity,
    :max_recovery_queue,
    :next_request_id,
    :max_response_bytes,
    :sampling_handler,
    :sampling_tools,
    :sampling_context,
    :elicitation_handler,
    :url_elicitation_handler,
    :elicitation_complete_handler,
    :log_handler,
    :progress_handler,
    :notification_handler,
    :client_info,
    :auth_input,
    :legacy_stdio_auth_metadata?,
    :worker_supervisor,
    :max_callback_request_ids,
    :roots,
    :roots_supported?,
    :session_stream,
    :max_sse_event_bytes,
    :sse_reconnect,
    :oauth,
    :timeout_ms,
    :max_in_flight
  ]
end
