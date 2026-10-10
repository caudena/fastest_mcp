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
      server.transforms
      |> transform(component, operation)
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

  # Server transforms run in order, and nil hides the component. Schemas a
  # transform changed are compiled again, as for provider transforms.
  defp transform([], component, _operation), do: component

  defp transform(transforms, component, operation) do
    transformed =
      Enum.reduce_while(transforms, component, fn transform, current ->
        case transform.(current, operation) do
          nil -> {:halt, nil}
          transformed -> {:cont, transformed}
        end
      end)

    transformed &&
      Component.refresh_compiled_schemas(
        transformed,
        operation.schema_cache,
        operation.schema_options || []
      )
  end
end
