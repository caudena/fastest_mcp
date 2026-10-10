defmodule FastestMCP.ErrorExposure do
  @moduledoc false

  alias FastestMCP.Component
  alias FastestMCP.Error
  alias FastestMCP.Server
  alias FastestMCP.Transport.Request

  def public_error(%Error{} = error, opts \\ []) do
    if mask_error_details?(opts) and maskable?(error) do
      %Error{error | message: generic_message(error, opts), details: %{}}
    else
      error
    end
  end

  def public_task(task, opts \\ []) when is_map(task) do
    case Map.get(task, :error) do
      %Error{} = error ->
        exposed_error =
          error
          |> public_error(task_error_opts(opts, task))

        task
        |> Map.put(:error, exposed_error)
        |> maybe_update_failure_message(error, exposed_error)

      _other ->
        task
    end
  end

  defp task_error_opts(opts, task) do
    opts
    |> Keyword.put_new(:task, task)
    |> Keyword.put_new(:component_type, Map.get(task, :component_type))
    |> Keyword.put_new(:target, Map.get(task, :target, Map.get(task, :method)))
  end

  defp maybe_update_failure_message(task, original_error, exposed_error) do
    if masked?(original_error, exposed_error) and is_binary(exposed_error.message) do
      Map.put(task, :failure_message, exposed_error.message)
    else
      task
    end
  end

  defp masked?(%Error{} = original, %Error{} = exposed) do
    original.message != exposed.message or original.details != exposed.details
  end

  defp maskable?(%Error{exposure: %{mask_error_details: true}}), do: true
  defp maskable?(_error), do: false

  defp mask_error_details?(opts) do
    case Keyword.get(opts, :mask_error_details) do
      nil ->
        case Keyword.get(opts, :server) do
          %Server{mask_error_details: value} -> value
          _other -> false
        end

      value ->
        value
    end
  end

  defp generic_message(%Error{exposure: %{message: message}}, _opts) when is_binary(message),
    do: message

  defp generic_message(%Error{exposure: exposure}, opts) do
    {request_kind, request_target} = request_call(Keyword.get(opts, :request))
    task = Keyword.get(opts, :task, %{})

    component_type =
      Keyword.get(opts, :component_type) ||
        Map.get(task, :component_type) ||
        (is_map(exposure) && Map.get(exposure, :component_type)) ||
        request_kind

    target =
      Keyword.get(opts, :target) ||
        Map.get(task, :target) ||
        Map.get(task, :method) ||
        request_target ||
        (is_map(exposure) && Map.get(exposure, :identifier))

    case {component_label(component_type), target} do
      {nil, nil} -> "request failed"
      {nil, value} -> "request #{inspect(value)} failed"
      {label, nil} -> "#{label} failed"
      {label, value} -> "#{label} #{inspect(value)} failed"
    end
  end

  # The kind and target of a call, read, or render request.
  defp request_call(%Request{method: method, payload: payload}) do
    case Component.call_kind(method) do
      nil -> {nil, nil}
      kind -> {kind, Map.get(payload, Component.call_param(kind))}
    end
  end

  defp request_call(_request), do: {nil, nil}

  defp component_label(:callback_task), do: "callback task"
  defp component_label(label) when is_binary(label), do: label

  defp component_label(kind) when kind in [:tool, :resource, :resource_template, :prompt],
    do: Component.label(kind)

  defp component_label(_label), do: nil
end
