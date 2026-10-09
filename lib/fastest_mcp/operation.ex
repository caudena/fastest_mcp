defmodule FastestMCP.Operation do
  @moduledoc """
  Runtime operation struct passed through middleware and transforms.

  The pipeline's executor sets `:result` and `:component` (the component that
  handled the operation, when there is one); middleware reads both from the
  operation its `next` function returns. See `FastestMCP.Middleware`.
  """

  defstruct [
    :server_name,
    :method,
    :component_type,
    :target,
    :version,
    :audience,
    :component,
    :result,
    :context,
    :transport,
    :call_supervisor,
    :task_store,
    :schema_cache,
    :schema_options,
    invocation: :local,
    task_request: false,
    task_ttl_ms: nil,
    captures: %{},
    arguments: %{}
  ]

  @type t :: %__MODULE__{
          server_name: String.t(),
          method: String.t(),
          component_type: atom(),
          target: String.t() | nil,
          version: String.t() | nil,
          audience: atom(),
          component: struct() | nil,
          result: term(),
          context: FastestMCP.Context.t(),
          transport: atom(),
          call_supervisor: pid() | atom(),
          task_store: pid() | atom() | nil,
          schema_cache: :ets.tid() | nil,
          schema_options: keyword(),
          invocation: :local | :protocol,
          task_request: boolean(),
          task_ttl_ms: pos_integer() | nil,
          captures: map(),
          arguments: map()
        }
end
