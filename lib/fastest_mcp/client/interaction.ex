defmodule FastestMCP.Client.Interaction do
  @moduledoc false
  alias FastestMCP.Client
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.Paginator
  alias FastestMCP.Error
  alias FastestMCP.Root
  alias FastestMCP.Telemetry

  @default_timeout_ms 5_000

  def request_with_mrtr(client, method, params, opts, normalizer \\ :identity) do
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)

    max_rounds =
      opts
      |> Keyword.get(:max_mrtr_rounds, snapshot.max_mrtr_rounds)
      |> FastestMCP.Client.Connection.normalize_positive_integer!(:max_mrtr_rounds)

    deadline = FastestMCP.Deadline.from_options(opts, @default_timeout_ms)

    do_request_with_mrtr(
      client,
      method,
      params,
      opts,
      snapshot,
      deadline,
      0,
      max_rounds,
      normalizer
    )
  end

  def request_with_mrtr_async(coordinator, ref, client, method, params, opts) do
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)

    max_rounds =
      opts
      |> Keyword.get(:max_mrtr_rounds, snapshot.max_mrtr_rounds)
      |> FastestMCP.Client.Connection.normalize_positive_integer!(:max_mrtr_rounds)

    deadline = FastestMCP.Deadline.from_options(opts, @default_timeout_ms)

    do_request_with_mrtr_async(
      coordinator,
      ref,
      client,
      method,
      params,
      opts,
      snapshot,
      deadline,
      0,
      max_rounds
    )
  end

  defp do_request_with_mrtr_async(
         coordinator,
         ref,
         client,
         method,
         params,
         opts,
         snapshot,
         deadline,
         round,
         max_rounds
       ) do
    timeout_ms = FastestMCP.Client.Catalog.remaining_timeout!(deadline, method)
    request_opts = Keyword.put(opts, :timeout_ms, timeout_ms)
    request = FastestMCP.Client.Requests.request_async(client, method, params, request_opts)
    send(coordinator, {:fastest_mcp_client_request, ref, request})

    result =
      try do
        FastestMCP.Client.Requests.await(request, timeout_ms)
      after
        send(coordinator, {:fastest_mcp_client_request_complete, ref, request.ref})
      end

    case result do
      %{"resultType" => "input_required"} when round < max_rounds ->
        input_requests = Map.get(result, "inputRequests", %{})

        responses =
          if map_size(input_requests) == 0,
            do: nil,
            else: fulfill_input_requests(client, input_requests, snapshot, deadline)

        retry_params = latest_mrtr_retry_params(params, result, responses)

        FastestMCP.Client.Trace.with_internal_client_span(
          "mcp.mrtr.continue",
          method,
          opts,
          %{"mcp.mrtr.round" => round + 1},
          fn continuation_opts ->
            do_request_with_mrtr_async(
              coordinator,
              ref,
              client,
              method,
              retry_params,
              continuation_opts,
              snapshot,
              deadline,
              round + 1,
              max_rounds
            )
          end
        )

      %{"resultType" => "input_required"} ->
        raise Error,
          code: :overloaded,
          message: "#{method} exceeded max_mrtr_rounds",
          details: %{max_mrtr_rounds: max_rounds}

      _complete ->
        result
    end
  end

  defp do_request_with_mrtr(
         client,
         method,
         params,
         opts,
         snapshot,
         deadline,
         round,
         max_rounds,
         normalizer
       ) do
    request_opts =
      Keyword.put(
        opts,
        :timeout_ms,
        FastestMCP.Client.Catalog.remaining_timeout!(deadline, method)
      )

    result = FastestMCP.Client.Requests.request(client, method, params, normalizer, request_opts)

    case result do
      %{"resultType" => "input_required"} when round < max_rounds ->
        input_requests = Map.get(result, "inputRequests", %{})

        responses =
          if map_size(input_requests) == 0,
            do: nil,
            else: fulfill_input_requests(client, input_requests, snapshot, deadline)

        retry_params = latest_mrtr_retry_params(params, result, responses)

        FastestMCP.Client.Trace.with_internal_client_span(
          "mcp.mrtr.continue",
          method,
          opts,
          %{"mcp.mrtr.round" => round + 1},
          fn continuation_opts ->
            do_request_with_mrtr(
              client,
              method,
              retry_params,
              continuation_opts,
              snapshot,
              deadline,
              round + 1,
              max_rounds,
              normalizer
            )
          end
        )

      %{"resultType" => "input_required"} ->
        raise Error,
          code: :overloaded,
          message: "#{method} exceeded max_mrtr_rounds",
          details: %{max_mrtr_rounds: max_rounds}

      _complete ->
        result
    end
  end

  def list_all(client, list_page, method, opts) do
    paginator_opts = Keyword.take(opts, [:max_pages, :max_items])
    request_opts = Keyword.drop(opts, [:cursor, :max_pages, :max_items])

    deadline = FastestMCP.Deadline.from_options(opts, @default_timeout_ms)

    fetch_page = fn cursor ->
      request_opts =
        Keyword.put(request_opts, :timeout_ms, FastestMCP.Deadline.remaining!(deadline, method))

      if is_nil(cursor) do
        capture_page(fn -> list_page.(client, request_opts) end)
      else
        page_opts =
          request_opts
          |> Keyword.put(:cursor, cursor)
          |> Keyword.put(:cache, :bypass)

        capture_page(fn -> list_page.(client, page_opts) end)
      end
    end

    case Paginator.fetch_all_with_meta(fetch_page, paginator_opts) do
      {:ok, %{items: items, page_count: page_count}} ->
        FastestMCP.Client.Trace.annotate_pagination_trace(opts, page_count, length(items))
        items

      {:error, exception} when is_exception(exception) ->
        raise exception

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} pagination failed",
          details: %{reason: inspect(reason)}
    end
  end

  def capture_page(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  end

  defp latest_mrtr_retry_params(params, result, responses) do
    params = Map.drop(params, ["inputResponses", "requestState"])

    params =
      if is_map(responses) and map_size(responses) > 0,
        do: Map.put(params, "inputResponses", responses),
        else: params

    if Map.has_key?(result, "requestState") do
      Map.put(params, "requestState", Map.fetch!(result, "requestState"))
    else
      params
    end
  end

  def fulfill_input_requests(
        %Client{} = client,
        input_requests,
        snapshot,
        deadline,
        task_id \\ nil
      ) do
    input_requests
    |> Enum.sort_by(fn {key, _request} -> to_string(key) end)
    |> Map.new(fn {key, request} ->
      result =
        run_with_deadline!(deadline, "input request #{inspect(key)}", fn ->
          fulfill_input_request!(client, key, request, snapshot, task_id)
        end)

      {key, result}
    end)
  end

  defp fulfill_input_request!(
         _client,
         _key,
         %{"method" => "roots/list"},
         snapshot,
         _task_id
       ) do
    unless snapshot.roots_supported? do
      raise Error,
        code: :missing_required_client_capability,
        message: "roots input is unsupported"
    end

    %{"resultType" => "complete", "roots" => Enum.map(snapshot.roots, &Root.to_wire/1)}
  end

  defp fulfill_input_request!(
         client,
         key,
         %{"method" => "sampling/createMessage", "params" => params},
         snapshot,
         task_id
       ) do
    context =
      mrtr_callback_context(client, key, "sampling/createMessage", params, snapshot, task_id)

    with handler when not is_nil(handler) <- snapshot.sampling_handler,
         {:ok, validators} <-
           FastestMCP.Client.Callbacks.validate_sampling_request_capabilities(params, snapshot),
         {:ok, result} <-
           FastestMCP.Client.Callbacks.sampling_response(handler, params, context, validators) do
      Map.put_new(result, "resultType", "complete")
    else
      nil ->
        raise Error, code: :missing_required_client_capability, message: "sampling is unsupported"

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp fulfill_input_request!(
         client,
         key,
         %{"method" => "elicitation/create", "params" => params},
         snapshot,
         task_id
       ) do
    context = mrtr_callback_context(client, key, "elicitation/create", params, snapshot, task_id)

    result =
      case Map.get(params, "mode", "form") do
        "url" when not is_nil(snapshot.url_elicitation_handler) ->
          FastestMCP.Client.Callbacks.url_elicitation_response(
            snapshot.url_elicitation_handler,
            params,
            context
          )

        "url" ->
          {:error,
           %Error{
             code: :missing_required_client_capability,
             message: "URL elicitation is unsupported"
           }}

        _form when not is_nil(snapshot.elicitation_handler) ->
          with :ok <-
                 FastestMCP.Client.Callbacks.validate_elicitation_request_schema(
                   params,
                   snapshot.schema_options
                 ) do
            FastestMCP.Client.Callbacks.elicitation_response(
              snapshot.elicitation_handler,
              params,
              context
            )
          end

        _form ->
          {:error,
           %Error{
             code: :missing_required_client_capability,
             message: "elicitation is unsupported"
           }}
      end

    case result do
      {:ok, response} -> Map.put_new(response, "resultType", "complete")
      {:error, %Error{} = error} -> raise error
    end
  end

  defp fulfill_input_request!(_client, _key, request, _snapshot, _task_id) do
    raise Error,
      code: :invalid_request,
      message: "unsupported MRTR input request #{inspect(Map.get(request, "method"))}"
  end

  defp mrtr_callback_context(client, key, method, params, snapshot, task_id) do
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

  defp run_with_deadline!(deadline, operation, fun) when is_function(fun, 0) do
    timeout_ms = FastestMCP.Client.Catalog.remaining_timeout!(deadline, operation)
    trace_context = Telemetry.current_context()

    task =
      Task.async(fn ->
        Telemetry.with_context(trace_context, fn ->
          try do
            {:ok, fun.()}
          rescue
            error -> {:raise, error, __STACKTRACE__}
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end
        end)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:raise, error, stacktrace}} ->
        reraise error, stacktrace

      {:ok, {:raise, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        raise Error, code: :timeout, message: "#{operation} timed out"
    end
  end
end
