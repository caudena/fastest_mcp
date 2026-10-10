defmodule FastestMCP.Operation do
  @moduledoc """
  Runtime operation struct passed through middleware and transforms.

  The pipeline's executor sets `:result` and `:component` (the component that
  handled the operation, when there is one); middleware reads both from the
  operation its `next` function returns, and `wire_result/1` gives the result
  as the client receives it. See `FastestMCP.Middleware`.
  """

  alias FastestMCP.Transport.Engine

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

  @doc """
  Returns the result of a `tools/call`, `resources/read`, or `prompts/get`
  operation as the client receives it: the `result` of the JSON-RPC response,
  a map with string keys, ready for `JSON.encode!/1`, for the protocol
  version of the operation's request, or the current version for an
  in-process call. Transports build their responses with the same code.

  Returns `nil` for any other operation, such as a list, whose response
  FastestMCP builds after the middleware has run. A result that isn't valid
  MCP raises the `FastestMCP.Error` that the request fails with.

  Call it in middleware on the operation that `next` returns; middleware added
  before yours can still change the result. See
  [Logging responses](middleware.md#logging-responses).
  """
  @spec wire_result(t()) :: map() | nil
  def wire_result(%__MODULE__{} = operation), do: Engine.wire_result(operation)
end
