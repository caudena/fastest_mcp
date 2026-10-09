defmodule FastestMCP.Client.CallbackContext do
  @moduledoc """
  Context passed to server-initiated client callbacks.

  Callbacks can cooperatively check cancellation and emit MCP progress without
  retaining transport details or constructing protocol notifications.
  """

  alias FastestMCP.Client.Requests
  alias FastestMCP.Error

  @enforce_keys [:client, :request_id, :method]
  defstruct [
    :client,
    :request_id,
    :method,
    :direction,
    :progress_token,
    :task_id,
    :sampling_tools,
    :sampling_context,
    :cancellation_ref,
    cancelled?: false
  ]

  @type t :: %__MODULE__{
          client: FastestMCP.Client.t(),
          request_id: String.t() | integer(),
          method: String.t(),
          direction: :server_to_client,
          progress_token: String.t() | integer() | nil,
          task_id: String.t() | nil,
          sampling_tools: term(),
          sampling_context: term(),
          cancellation_ref: :atomics.atomics_ref() | nil,
          cancelled?: boolean()
        }

  @doc "Returns whether the peer cancelled this callback or its task, or its client stopped."
  defdelegate cancelled?(context), to: Requests, as: :callback_cancelled?

  @doc "Sends a monotonic progress update for this callback; raises on failure."
  def report_progress(%__MODULE__{} = context, progress, opts \\ []),
    do: Error.unwrap!(Requests.report_progress(context, progress, opts))
end
