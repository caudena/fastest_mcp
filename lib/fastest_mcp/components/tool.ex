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
    :completions,
    :inject,
    :task,
    :timeout,
    :output_schema,
    :compiled,
    authorization: [],
    policy_state: %{},
    tags: MapSet.new(),
    enabled: true,
    visibility: [:model],
    meta: %{}
  ]
end
