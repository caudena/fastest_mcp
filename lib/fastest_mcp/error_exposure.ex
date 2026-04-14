defmodule FastestMCP.ErrorExposure do
  @moduledoc false

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

  defp generic_message(%Error{exposure: exposure}, opts) do
    component_type =
      Keyword.get(opts, :component_type) ||
        get_in(opts, [:task, :component_type]) ||
        (is_map(exposure) && Map.get(exposure, :component_type)) ||
        request_component_type(Keyword.get(opts, :request))

    target =
      Keyword.get(opts, :target) ||
        get_in(opts, [:task, :target]) ||
        get_in(opts, [:task, :method]) ||
        request_target(Keyword.get(opts, :request)) ||
        (is_map(exposure) && Map.get(exposure, :identifier))

    case {component_label(component_type), target} do
      {nil, nil} -> "request failed"
      {nil, value} -> "request #{inspect(value)} failed"
      {label, nil} -> "#{label} failed"
      {label, value} -> "#{label} #{inspect(value)} failed"
    end
  end

  defp request_component_type(%Request{method: "tools/call"}), do: :tool
  defp request_component_type(%Request{method: "resources/read"}), do: :resource
  defp request_component_type(%Request{method: "prompts/get"}), do: :prompt
  defp request_component_type(_request), do: nil

  defp request_target(%Request{method: "tools/call", payload: %{"name" => name}}), do: name
  defp request_target(%Request{method: "resources/read", payload: %{"uri" => uri}}), do: uri
  defp request_target(%Request{method: "prompts/get", payload: %{"name" => name}}), do: name
  defp request_target(_request), do: nil

  defp component_label(:tool), do: "tool"
  defp component_label(:resource), do: "resource"
  defp component_label(:resource_template), do: "resource"
  defp component_label(:prompt), do: "prompt"
  defp component_label(:callback_task), do: "callback task"
  defp component_label(label) when is_binary(label), do: label
  defp component_label(_label), do: nil
end
