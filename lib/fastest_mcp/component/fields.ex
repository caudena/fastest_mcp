defmodule FastestMCP.Component.Fields do
  @moduledoc false
  # Struct fields shared by every component kind. The component structs read
  # this at compile time, so it must not depend on other FastestMCP modules.

  def common do
    [
      :name,
      # The server whose definition holds the component; nil for components
      # built by providers. `FastestMCP.SamplingTool.from_tool/2` calls back
      # into it.
      :server_name,
      :version,
      :title,
      :description,
      :icons,
      :inject,
      :task,
      :timeout,
      :compiled,
      authorization: [],
      policy_state: %{},
      tags: MapSet.new(),
      enabled: true,
      visibility: [:model],
      meta: %{}
    ]
  end
end
