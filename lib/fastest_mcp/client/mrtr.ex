defmodule FastestMCP.Client.Mrtr do
  @moduledoc false
  # Multi-round-trip requests (MCP 2026-07-28). An input_required result is
  # answered with the connection's roots, sampling and elicitation handlers
  # and retried with a fresh request id and the latest request state, within
  # the request's deadline and a bounded number of rounds.

  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.Callbacks
  alias FastestMCP.Client.Connection
  alias FastestMCP.Client.Requests
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Trace
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Root
  alias FastestMCP.Telemetry

  # `snapshot` is the connection's callback configuration, fetched on the
  # first input_required result when nil; `send` delivers one round.
  def run(client, %Spec{} = spec, opts, snapshot \\ nil, send \\ &Requests.run/2),
    do: step(client, spec, 0, %{max: opts[:max_mrtr_rounds], snapshot: snapshot, send: send})

  defp step(client, spec, round, ctx) do
    case ctx.send.(client, spec) do
      {:ok, %{"resultType" => "input_required"} = result} ->
        with {:ok, ctx} <- with_snapshot(client, ctx),
             :ok <- check_round(spec.method, round, ctx.max || ctx.snapshot.max_mrtr_rounds),
             {:ok, responses} <-
               respond(client, Map.get(result, "inputRequests", %{}), ctx.snapshot, spec.deadline) do
          retry = %{spec | params: retry_params(spec.params, result, responses)}
          attrs = %{"mcp.mrtr.round" => round + 1}

          Trace.child(spec.trace, "mcp.mrtr.continue", spec.method, attrs, fn trace ->
            step(client, if(trace, do: Spec.traced(retry, trace), else: retry), round + 1, ctx)
          end)
        end

      result ->
        result
    end
  end

  defp with_snapshot(_client, %{snapshot: %{}} = ctx), do: {:ok, ctx}

  defp with_snapshot(client, ctx) do
    with {:ok, snapshot} <- Connection.call(client, :snapshot),
         do: {:ok, %{ctx | snapshot: snapshot}}
  end

  defp check_round(_method, round, max) when round < max, do: :ok

  defp check_round(method, _round, max) do
    {:error,
     %Error{
       code: :overloaded,
       message: "#{method} exceeded max_mrtr_rounds",
       details: %{max_mrtr_rounds: max}
     }}
  end

  # Only the latest round's responses and request state are sent.
  defp retry_params(params, result, responses) do
    params = Map.drop(params, ["inputResponses", "requestState"])

    params =
      if map_size(responses) > 0, do: Map.put(params, "inputResponses", responses), else: params

    case result do
      %{"requestState" => state} -> Map.put(params, "requestState", state)
      _result -> params
    end
  end

  # Answers input requests in key order, each within the deadline.
  def respond(client, input_requests, snapshot, deadline, task_id \\ nil) do
    input_requests
    |> Enum.sort_by(fn {key, _request} -> to_string(key) end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, request}, {:ok, responses} ->
      operation = "input request #{inspect(key)}"

      case bounded(deadline, operation, fn -> answer(client, key, request, snapshot, task_id) end) do
        {:ok, response} -> {:cont, {:ok, Map.put(responses, key, response)}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp answer(_client, _key, %{"method" => "roots/list"}, snapshot, _task_id) do
    if is_list(snapshot.roots),
      do:
        {:ok, %{"resultType" => "complete", "roots" => Enum.map(snapshot.roots, &Root.to_wire/1)}},
      else: {:error, unsupported("roots input is unsupported")}
  end

  defp answer(
         client,
         key,
         %{"method" => "sampling/createMessage", "params" => params},
         snapshot,
         task_id
       ) do
    context = context(client, key, "sampling/createMessage", params, snapshot, task_id)

    if is_nil(snapshot.sampling_handler) do
      {:error, unsupported("sampling is unsupported")}
    else
      with {:ok, validators} <- Callbacks.validate_sampling_request_capabilities(params, snapshot),
           {:ok, result} <-
             Callbacks.sampling_response(snapshot.sampling_handler, params, context, validators),
           do: {:ok, Map.put_new(result, "resultType", "complete")}
    end
  end

  defp answer(
         client,
         key,
         %{"method" => "elicitation/create", "params" => params},
         snapshot,
         task_id
       ) do
    context = context(client, key, "elicitation/create", params, snapshot, task_id)

    result =
      case Map.get(params, "mode", "form") do
        "url" when not is_nil(snapshot.url_elicitation_handler) ->
          Callbacks.url_elicitation_response(snapshot.url_elicitation_handler, params, context)

        "url" ->
          {:error, unsupported("URL elicitation is unsupported")}

        _form when not is_nil(snapshot.elicitation_handler) ->
          with :ok <-
                 Callbacks.validate_elicitation_request_schema(params, snapshot.schema_options),
               do: Callbacks.elicitation_response(snapshot.elicitation_handler, params, context)

        _form ->
          {:error, unsupported("elicitation is unsupported")}
      end

    with {:ok, response} <- result, do: {:ok, Map.put_new(response, "resultType", "complete")}
  end

  defp answer(_client, _key, request, _snapshot, _task_id) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "unsupported MRTR input request #{inspect(Map.get(request, "method"))}"
     }}
  end

  defp unsupported(message),
    do: %Error{code: :missing_required_client_capability, message: message}

  defp context(client, key, method, params, snapshot, task_id) do
    %CallbackContext{
      client: client,
      request_id: key,
      method: method,
      direction: :server_to_client,
      progress_token: get_in(params, ["_meta", "progressToken"]),
      task_id: task_id,
      sampling_tools: snapshot.sampling_tools,
      sampling_context: snapshot.sampling_context,
      cancellation_ref: :atomics.new(1, []),
      cancelled?: false
    }
  end

  # Runs a handler in a task bounded by the deadline and the caller's trace
  # context; a handler past the deadline is killed.
  defp bounded(deadline, operation, fun) do
    with {:ok, timeout} <- Deadline.check(deadline, operation) do
      trace_context = Telemetry.current_context()

      task =
        Task.async(fn ->
          Telemetry.with_context(trace_context, fn ->
            try do
              {:ok, fun.()}
            catch
              kind, reason -> {:raise, kind, reason, __STACKTRACE__}
            end
          end)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} -> result
        {:ok, {:raise, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
        {:exit, reason} -> {:error, Connection.exit_error(reason)}
        nil -> {:error, Error.timeout(operation)}
      end
    end
  end
end
