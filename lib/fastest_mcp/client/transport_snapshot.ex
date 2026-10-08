defmodule FastestMCP.Client.TransportSnapshot do
  @moduledoc false
  # Worker copies contain transport configuration, never catalogs, pending
  # requests, callback task registries, or readiness/recovery waiters.
  @fields [
    :client_pid,
    :transport,
    :session_id,
    :initialize_result,
    :discovery_result,
    :protocol_preference,
    :selected_protocol_version,
    :extensions,
    :advertised_client_capabilities,
    :schema_options,
    :server_identity,
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
    :roots,
    :roots_supported?,
    :max_sse_event_bytes,
    :sse_reconnect,
    :oauth,
    :timeout_ms
  ]
  defstruct @fields ++ [:lifecycle]
  @type t :: %__MODULE__{}

  def new(%__MODULE__{} = snapshot), do: snapshot

  def new(state) do
    struct!(__MODULE__, Map.take(state, @fields))
    |> Map.put(:lifecycle, %{session_generation: state.lifecycle.session_generation})
  end
end
