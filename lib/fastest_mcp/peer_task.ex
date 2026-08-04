defmodule FastestMCP.PeerTask do
  @moduledoc """
  Handle for a task owned by the connected MCP peer.

  This is intentionally distinct from `FastestMCP.BackgroundTask`, which is
  local work owned by the FastestMCP runtime, and from
  `FastestMCP.Client.Task`, which belongs to a standalone client process.
  Peer tasks are scoped to the exact server session that created them.
  """

  alias FastestMCP.Session

  @enforce_keys [:server_name, :session_id, :task_id]
  defstruct [:server_name, :session_id, :task_id, :kind, :target]

  @type kind :: :sampling | :elicitation | :generic

  @type t :: %__MODULE__{
          server_name: String.t(),
          session_id: String.t(),
          task_id: String.t(),
          kind: kind(),
          target: String.t() | nil
        }

  @doc "Builds a peer-task handle from validated attributes."
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      server_name: required_string!(attrs, :server_name),
      session_id: required_string!(attrs, :session_id),
      task_id: required_string!(attrs, :task_id),
      kind: normalize_kind(Map.get(attrs, :kind, :generic)),
      target: optional_string!(attrs, :target)
    }
  end

  @doc "Fetches the latest task state from the connected peer."
  def fetch(%__MODULE__{} = task, opts \\ []) do
    session_call(:peer_task_fetch, task, opts)
  end

  @doc "Waits for the peer task to reach a requested or terminal state."
  def wait(%__MODULE__{} = task, opts \\ []) do
    session_call(:peer_task_wait, task, opts)
  end

  @doc "Fetches the peer task's terminal result."
  def result(%__MODULE__{} = task, opts \\ []) do
    session_call(:peer_task_result, task, opts)
  end

  @doc "Requests cancellation of the peer-owned task."
  def cancel(%__MODULE__{} = task, opts \\ []) do
    session_call(:peer_task_cancel, task, opts)
  end

  @doc "Registers a callback for peer task status changes."
  def on_status_change(%__MODULE__{} = task, callback) when is_function(callback) do
    session_call(:peer_task_on_status_change, task, callback)
  end

  defp session_call(function, task, argument) do
    if function_exported?(Session, function, 4) do
      apply(Session, function, [task.server_name, task.session_id, task.task_id, argument])
    else
      {:error, :session_unavailable}
    end
  end

  defp required_string!(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      other -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp optional_string!(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      other -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp normalize_kind(kind) when kind in [:sampling, :elicitation, :generic], do: kind

  defp normalize_kind(kind) do
    raise ArgumentError,
          "peer task kind must be :sampling, :elicitation, or :generic, got: #{inspect(kind)}"
  end
end
