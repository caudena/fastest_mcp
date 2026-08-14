defmodule FastestMCP.Client.CallbackContext do
  @moduledoc """
  Context passed to server-initiated client callbacks.

  Callbacks can cooperatively check cancellation and emit MCP progress without
  retaining transport details or constructing protocol notifications.
  """

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

  @doc "Returns whether the peer cancelled this callback or its task."
  def cancelled?(%__MODULE__{} = context) do
    FastestMCP.Client.callback_cancelled?(context)
  end

  @doc "Sends a monotonic progress update for this callback."
  def report_progress(%__MODULE__{} = context, progress, opts \\ []) do
    FastestMCP.Client.report_progress(context, progress, opts)
  end
end
