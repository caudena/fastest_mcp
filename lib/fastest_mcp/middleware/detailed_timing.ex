defmodule FastestMCP.Middleware.DetailedTiming do
  @moduledoc """
  Middleware that logs operation-specific timing labels.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry immutable configuration. Dispatch calls the module with that configuration;
  runtime state is owned separately by the server.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Operation

  @doc "Builds timing middleware with operation-specific labels."
  def new(opts \\ []), do: Timing.new(Keyword.put(opts, :label, &label/1))

  @doc "Runs the shared timing implementation."
  defdelegate call(config, operation, next), to: Timing

  @doc "Builds the label recorded for a detailed timing sample."
  def label(%Operation{method: "tools/call", target: target}), do: "Tool '#{target}'"
  def label(%Operation{method: "resources/read", target: target}), do: "Resource '#{target}'"
  def label(%Operation{method: "prompts/get", target: target}), do: "Prompt '#{target}'"
  def label(%Operation{method: "tools/list"}), do: "List tools"
  def label(%Operation{method: "resources/list"}), do: "List resources"
  def label(%Operation{method: "resources/templates/list"}), do: "List resource templates"
  def label(%Operation{method: "prompts/list"}), do: "List prompts"
  def label(%Operation{method: "initialize"}), do: "Initialize"
  def label(%Operation{method: "ping"}), do: "Ping"
  def label(%Operation{method: method}), do: "Request #{method}"
end
