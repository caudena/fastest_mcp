defmodule FastestMCP.ComponentPolicy do
  @moduledoc """
  Applies component visibility and policy rules for a given operation.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Authorization
  alias FastestMCP.Component
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Error

  @doc "Applies the current policy or transform."
  def apply(server, component, operation, opts \\ []) do
    raise_on_filtered = Keyword.get(opts, :raise_on_filtered, true)

    case apply_result(server, component, operation) do
      {:ok, transformed} ->
        transformed

      {:error, %Error{} = error} ->
        filtered(raise_on_filtered, error)
    end
  end

  @doc false
  def apply_result(server, component, operation) do
    transformed =
      Enum.reduce(server.transforms, component, fn transform, current ->
        if current, do: transform.(current, operation), else: nil
      end)
      |> ComponentVisibility.apply_server_rules(operation.server_name)
      |> ComponentVisibility.apply_session_rules(operation.context)

    cond do
      is_nil(transformed) ->
        {:error,
         %Error{
           code: :filtered,
           message: "component #{inspect(operation.target)} was filtered by a transform"
         }}

      not Component.enabled?(transformed) ->
        {:error,
         %Error{
           code: :disabled,
           message: "component #{inspect(operation.target)} is disabled"
         }}

      operation.audience not in Component.visibility(transformed) ->
        {:error,
         %Error{
           code: :not_visible,
           message:
             "component #{inspect(operation.target)} is not visible to #{operation.audience}"
         }}

      true ->
        case Authorization.authorize_component(transformed, operation.context, operation) do
          :ok -> {:ok, transformed}
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp filtered(true, %Error{} = error), do: raise(error)
  defp filtered(false, %Error{}), do: nil
end
