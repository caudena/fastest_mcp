defmodule FastestMCP.Client.CallbackProgress do
  @moduledoc false

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Progress, as: ProtocolProgress

  def prepare(
        _state,
        %CallbackContext{progress_token: nil},
        _progress,
        _opts
      ) do
    {:error,
     %Error{
       code: :bad_request,
       message: "callback request did not include a progress token"
     }}
  end

  def prepare(state, %CallbackContext{} = context, progress, opts) do
    with {:ok, owner} <- callback_progress_owner(state, context),
         {:ok, progress_total} <-
           validate_progress_update(
             progress,
             owner[:last_progress],
             progress_total(opts),
             owner[:progress_total]
           ),
         params <-
           %{
             "progressToken" => context.progress_token,
             "progress" => progress
           }
           |> maybe_put("total", opts[:total])
           |> maybe_put("message", opts[:message]) do
      {:ok, params, store_callback_progress(state, context, progress, progress_total)}
    end
  end

  defp callback_progress_owner(state, %CallbackContext{task_id: task_id})
       when is_binary(task_id) do
    case Map.get(state.tasks, task_id) do
      %{status: :working} = task -> {:ok, task}
      %{status: :cancelled} -> {:error, cancelled_callback_error()}
      _other -> {:error, inactive_callback_error()}
    end
  end

  defp callback_progress_owner(state, %CallbackContext{request_id: request_id}) do
    case Map.get(state.requests, request_id) do
      %{cancelled?: false} = request -> {:ok, request}
      %{cancelled?: true} -> {:error, cancelled_callback_error()}
      _other -> {:error, inactive_callback_error()}
    end
  end

  defp store_callback_progress(
         state,
         %CallbackContext{task_id: task_id},
         progress,
         progress_total
       )
       when is_binary(task_id) do
    state
    |> put_in(
      [Access.key(:tasks), task_id, :last_progress],
      progress
    )
    |> put_in(
      [Access.key(:tasks), task_id, :progress_total],
      progress_total
    )
  end

  defp store_callback_progress(
         state,
         %CallbackContext{request_id: request_id},
         progress,
         progress_total
       ) do
    state
    |> put_in(
      [Access.key(:requests), request_id, :last_progress],
      progress
    )
    |> put_in(
      [Access.key(:requests), request_id, :progress_total],
      progress_total
    )
  end

  def validate_progress_update(progress, previous, total, previous_total) do
    case ProtocolProgress.validate_update(progress, previous, total, previous_total) do
      {:ok, total} ->
        {:ok, total}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: progress_validation_message(reason),
           details: %{
             reason: reason,
             previous: previous,
             progress: progress,
             previous_total: previous_total,
             total: progress_total_value(total)
           }
         }}
    end
  end

  def progress_total(params) do
    ProtocolProgress.total(params)
  end

  defp progress_total_value({:provided, total}) do
    total
  end

  defp progress_total_value(:absent) do
    nil
  end

  defp progress_validation_message(:invalid_progress) do
    "progress must be a number"
  end

  defp progress_validation_message(:non_increasing_progress) do
    "progress must increase with every notification"
  end

  defp progress_validation_message(:invalid_total) do
    "progress total must be a number"
  end

  defp cancelled_callback_error do
    %Error{code: :cancelled, message: "client callback was cancelled"}
  end

  defp inactive_callback_error do
    %Error{code: :bad_request, message: "client callback is no longer active"}
  end
end
