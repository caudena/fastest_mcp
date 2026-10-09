defmodule FastestMCP.ComponentPolicy do
  @moduledoc false

  alias FastestMCP.Authorization
  alias FastestMCP.Component
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Error

  def apply_result(server, component, operation) do
    with {:ok, transformed} <- prepare_result(server, component, operation),
         {:ok, authorized} <- authorize_result(transformed, operation) do
      {:ok, authorized}
    end
  end

  def prepare_result(server, component, operation) do
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
        {:ok, transformed}
    end
  end

  def authorize_result(component, operation) do
    case Authorization.authorize_component(component, operation.context, operation) do
      :ok -> {:ok, component}
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
