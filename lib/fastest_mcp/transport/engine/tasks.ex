defmodule FastestMCP.Transport.Engine.Tasks do
  @moduledoc false
  # Task methods of `Transport.Engine`. Legacy requests reach the tasks of
  # their session; modern requests (the Tasks extension) reach tasks by owner.
  # `tasks/update` is modern only, `tasks/result` and `tasks/list` legacy only.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Pagination
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Engine.Components
  alias FastestMCP.Transport.Request

  def handle(runtime, %Request{method: "tasks/get"} = request, opts) do
    with {:ok, access} <- access_opts(runtime, request),
         {:ok, task_id} <- Request.fetch_param(request, "taskId"),
         {:ok, task} <- fetch_protocol_task(runtime, task_id, access, request) do
      Engine.wire(fn ->
        TaskWire.task(
          task,
          public_opts(runtime) ++
            [
              protocol_version: request.protocol_version,
              result_serializer: result_serializer(runtime, task, request, opts)
            ]
        )
      end)
    end
  end

  def handle(runtime, %Request{method: "tasks/update", profile: :modern} = request, _opts) do
    with {:ok, access} <- access_opts(runtime, request),
         {:ok, task_id} <- Request.fetch_param(request, "taskId"),
         {:ok, _task} <- fetch_protocol_task(runtime, task_id, access, request),
         {:ok, responses} <- Request.fetch_param(request, "inputResponses"),
         {:ok, _task} <- FastestMCP.update_task(runtime.server.name, task_id, responses, access),
         do: {:ok, TaskWire.acknowledgement(protocol_version: request.protocol_version)}
  end

  def handle(runtime, %Request{method: "tasks/result", profile: profile} = request, opts)
      when profile != :modern do
    with {:ok, access} <- access_opts(runtime, request),
         {:ok, task_id} <- Request.fetch_param(request, "taskId"),
         {:ok, task} <- FastestMCP.fetch_task(runtime.server.name, task_id, access) do
      result_opts = Keyword.put(access, :request_metadata, Engine.context_metadata(request))

      case FastestMCP.task_result(runtime.server.name, task_id, result_opts) do
        {:ok, result} ->
          serializer = result_serializer(runtime, task, request, opts)
          Engine.wire(fn -> result |> serializer.() |> TaskWire.task_result(task.id) end)

        {:error, error} ->
          {:error,
           error
           |> Error.with_meta(TaskWire.related_task_meta(task.id))
           |> ErrorExposure.public_error(public_opts(runtime) ++ [task: task])}
      end
    end
  end

  def handle(runtime, %Request{method: "tasks/list", profile: profile} = request, opts)
      when profile != :modern do
    with {:ok, access} <- access_opts(runtime, request),
         {:ok, %{tasks: tasks}} <- FastestMCP.list_tasks(runtime.server.name, access),
         {:ok, fingerprint} <- Components.pagination_fingerprint(runtime, request, opts),
         {:ok, page} <-
           Pagination.wire_page(tasks,
             secret: runtime.pagination_cursor_secret,
             scope: request.method,
             fingerprint: fingerprint,
             cursor: Map.get(request.payload, "cursor"),
             key: & &1.id
           ) do
      {:ok,
       TaskWire.task_list(
         %{tasks: page.items, next_cursor: page.next_cursor},
         public_opts(runtime)
       )}
    end
  end

  def handle(runtime, %Request{method: "tasks/cancel"} = request, _opts) do
    with {:ok, access} <- access_opts(runtime, request),
         {:ok, task_id} <- Request.fetch_param(request, "taskId"),
         do: cancel(runtime, task_id, access, request)
  end

  def handle(_runtime, %Request{} = request, _opts), do: Engine.method_not_found(request)

  # A modern cancel acknowledges; cancelling a finished task changes nothing.
  defp cancel(runtime, task_id, access, %Request{profile: :modern} = request) do
    with {:ok, task} <- fetch_protocol_task(runtime, task_id, access, request),
         {:ok, _task} <-
           if(task.status in [:completed, :failed, :cancelled],
             do: {:ok, task},
             else: FastestMCP.cancel_task(runtime.server.name, task_id, access)
           ),
         do: {:ok, TaskWire.acknowledgement(protocol_version: request.protocol_version)}
  end

  defp cancel(runtime, task_id, access, _request) do
    with {:ok, task} <- FastestMCP.cancel_task(runtime.server.name, task_id, access),
         do: {:ok, TaskWire.task(task, public_opts(runtime))}
  end

  defp access_opts(_runtime, %Request{profile: :modern} = request),
    do: {:ok, [owner_fingerprint: auth_owner(request)]}

  defp access_opts(runtime, %Request{} = request) do
    case Request.explicit_session_id(request) do
      {:ok, session_id} ->
        with {:ok, owner} <- owner_fingerprint(runtime, request, session_id),
             do: {:ok, [session_id: session_id, owner_fingerprint: owner]}

      :error ->
        Engine.error(:bad_request, "task requests require an explicit session_id")
    end
  end

  defp auth_owner(%Request{auth_result: %AuthResult{} = auth_result}),
    do: TaskOwner.from_principal_auth(auth_result.principal, auth_result.auth)

  defp auth_owner(_request), do: nil

  # Without a transport auth result, the owner is the identity the server's
  # auth resolves for the request's session.
  defp owner_fingerprint(_runtime, %Request{auth_result: %AuthResult{}} = request, _session_id),
    do: {:ok, auth_owner(request)}

  defp owner_fingerprint(runtime, request, session_id) do
    with {:ok, context} <-
           OperationPipeline.request_context(runtime, Engine.session_opts(request, session_id)),
         {:ok, context} <- Auth.resolve(runtime.server.auth, context, request.auth_input),
         do: {:ok, TaskOwner.from_context(context)}
  end

  # A task is only visible under the protocol profile that created it.
  defp fetch_protocol_task(runtime, task_id, access, request) do
    with {:ok, task} <- FastestMCP.fetch_task(runtime.server.name, task_id, access) do
      if is_modern(task.protocol_version) == (request.profile == :modern) do
        {:ok, task}
      else
        {:error, %{Error.invalid_task_id(task_id) | details: %{jsonrpc_code: -32_602}}}
      end
    end
  end

  defp result_serializer(runtime, %{component_type: kind} = task, request, opts)
       when kind in [:tool, :resource, :prompt] do
    component = if kind != :prompt, do: task_component(runtime, kind, task, opts)
    &Components.serialize(kind, task.target, component, &1, request, opts)
  end

  defp result_serializer(_runtime, _task, _request, _opts), do: & &1

  # Tasks keep the component that ran; a backend may not.
  defp task_component(_runtime, _kind, %{component_descriptor: %{} = component}, _opts),
    do: component

  defp task_component(runtime, kind, %{target: target}, opts) when not is_nil(target),
    do: Components.visible_component(runtime, kind, target, opts)

  defp task_component(_runtime, _kind, _task, _opts), do: nil

  defp public_opts(runtime), do: [mask_error_details: runtime.server.mask_error_details]
end
