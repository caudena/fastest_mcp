defmodule FastestMCP.Operation do
  @moduledoc """
  Runtime operation struct passed through middleware and transforms.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  defstruct [
    :server_name,
    :method,
    :component_type,
    :target,
    :version,
    :audience,
    :component,
    :context,
    :transport,
    :call_supervisor,
    :task_supervisor,
    :task_store,
    :schema_cache,
    :schema_options,
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
          context: FastestMCP.Context.t(),
          transport: atom(),
          call_supervisor: pid() | atom(),
          task_supervisor: pid() | atom() | nil,
          task_store: pid() | atom() | nil,
          schema_cache: :ets.tid() | nil,
          schema_options: keyword(),
          task_request: boolean(),
          task_ttl_ms: pos_integer() | nil,
          captures: map(),
          arguments: map()
        }
end
