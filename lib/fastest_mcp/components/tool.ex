defmodule FastestMCP.Components.Tool do
  @moduledoc """
  Defines the runtime struct used for tool components.

  These structs are the compiled component shapes used by the runtime. The
  builder APIs, providers, registry, serializers, and transports all agree
  on this explicit representation so they do not need to keep the original
  DSL input around.

  Applications usually do not construct these structs by hand. Prefer the
  corresponding `FastestMCP.Server` or provider helpers and let compilation
  produce the runtime shape for you.
  """

  defstruct [
    :server_name,
    :name,
    :version,
    :title,
    :description,
    :icons,
    :annotations,
    :input_schema,
    :compiled_input_schema,
    :completions,
    :inject,
    :task,
    :timeout,
    :output_schema,
    :compiled_output_schema,
    :compiled,
    authorization: [],
    policy_state: %{},
    tags: MapSet.new(),
    enabled: true,
    visibility: [:model],
    meta: %{}
  ]

  @type t :: %__MODULE__{
          server_name: String.t() | atom() | nil,
          name: String.t() | nil,
          version: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          icons: list() | nil,
          annotations: map() | nil,
          input_schema: boolean() | map() | nil,
          compiled_input_schema: term(),
          completions: term(),
          inject: term(),
          task: term(),
          timeout: non_neg_integer() | nil,
          output_schema: boolean() | map() | nil,
          compiled_output_schema: term(),
          compiled: term(),
          authorization: list(),
          policy_state: map(),
          tags: MapSet.t(),
          enabled: boolean(),
          visibility: list(),
          meta: map()
        }
end
