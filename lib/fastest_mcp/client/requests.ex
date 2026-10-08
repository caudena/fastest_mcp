defmodule FastestMCP.Client.Requests do
  @moduledoc false
  alias FastestMCP.Client
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Request, as: ClientRequest
  alias FastestMCP.Error
  alias FastestMCP.Telemetry

  @default_timeout_ms 5_000

  @doc "Runs the MCP initialize handshake."
  def initialize(client_ref, params \\ %{}, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    case GenServer.call(client.pid, :begin_initialize) do
      :ok ->
        try do
          result = request(client, "initialize", Map.new(params), :initialize, opts)
          :ok = notification(client, "notifications/initialized", %{}, opts)
          :ok = GenServer.call(client.pid, :finish_initialize)
          result
        rescue
          error ->
            _ = FastestMCP.Client.Connection.fail_initialize(client, error)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            _ = FastestMCP.Client.Connection.fail_initialize(client, {kind, reason})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, %Error{} = error} ->
        raise error
    end
  end

  @doc "Runs modern stateless server discovery and selects MCP 2026 for this connection."
  def discover(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    case GenServer.call(client.pid, :begin_discover) do
      {:ok, token} ->
        try do
          deadline = FastestMCP.Deadline.from_options(opts, @default_timeout_ms)
          result = discover_with_version_retry(client, Keyword.put(opts, :deadline, deadline), 1)

          case GenServer.call(client.pid, {:finish_discover, token, result}) do
            :ok -> result
            {:error, %Error{} = error} -> raise error
          end
        rescue
          error ->
            _ = FastestMCP.Client.Connection.fail_discover(client, token, error)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            _ = FastestMCP.Client.Connection.fail_discover(client, token, {kind, reason})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp discover_with_version_retry(client, opts, retries_left) do
    timeout = FastestMCP.Deadline.remaining!(opts[:deadline], "server/discover")
    request(client, "server/discover", %{}, :identity, Keyword.put(opts, :timeout_ms, timeout))
  rescue
    error in Error ->
      if retries_left > 0 and retryable_unsupported_version?(error) do
        discover_with_version_retry(client, opts, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retryable_unsupported_version?(%Error{
         code: :unsupported_protocol_version,
         details: details
       })
       when is_map(details) do
    supported = Map.get(details, :supported, Map.get(details, "supported", []))
    "2026-07-28" in List.wrap(supported)
  end

  defp retryable_unsupported_version?(_error), do: false

  @doc "Starts a modern subscription/listen request and returns its request handle."
  def listen(client_ref, filter \\ %{}, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    params = %{"notifications" => Map.new(filter)}

    request_async(
      client,
      "subscriptions/listen",
      params,
      Keyword.put(opts, :timeout_ms, :infinity)
    )
  end

  @doc "Runs a ping request."
  def ping(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    request(client, "ping", %{}, :identity, opts)
  end

  @doc "Requests that the server emit logs at `level` or higher."
  def set_log_level(client_ref, level, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    level = FastestMCP.Client.Codec.normalize_log_level!(level)

    _result =
      request(
        client,
        "logging/setLevel",
        %{"level" => level} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
        :identity,
        opts
      )

    :ok
  end

  @doc "Starts a low-level MCP request and returns an opaque cancellable handle."
  def request_async(client_ref, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    %Client{pid: pid} = client = FastestMCP.Client.Connection.pin_client!(client_ref)
    opts = FastestMCP.Deadline.request_options(opts, @default_timeout_ms, method)
    timeout_ms = opts[:timeout_ms]
    {trace, opts} = FastestMCP.Client.Trace.prepare_async_request_trace(method, params, opts)

    try do
      case GenServer.call(
             pid,
             {:request_async, method, params, :identity, opts, self()},
             FastestMCP.Client.Connection.call_timeout(timeout_ms)
           ) do
        {:ok, ref, request_id, task_augmented} ->
          %ClientRequest{
            client: client,
            ref: ref,
            request_id: request_id,
            method: method,
            owner: self(),
            monitor: Process.monitor(pid),
            task_augmented: task_augmented
          }

        {:error, exception} when is_exception(exception) ->
          raise exception
      end
    rescue
      error ->
        FastestMCP.Client.Trace.finish_started_client_span(trace, {:error, error})
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        FastestMCP.Client.Trace.finish_started_client_span(trace, {:error, {kind, reason}})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Sends a low-level MCP request and returns its raw result."
  def request(client_ref, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    request(client, method, params, :identity, opts)
  end

  @doc "Waits for an asynchronous request and returns its raw MCP result."
  def await(request, timeout \\ :infinity)

  def await(%ClientRequest{owner: owner} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_client_response, ref, {:ok, result}} when ref == request.ref ->
        Process.demonitor(request.monitor, [:flush])
        result

      {:fastest_mcp_client_response, ref, {:error, exception}}
      when ref == request.ref and is_exception(exception) ->
        Process.demonitor(request.monitor, [:flush])
        raise exception

      {:DOWN, monitor, :process, _pid, reason} when monitor == request.monitor ->
        raise FastestMCP.OperationResult.exit_error(reason)
    after
      timeout ->
        Process.demonitor(request.monitor, [:flush])
        # Completion or the coordinator's request timer can win this race.
        # Cleanup failure must not replace the caller's timeout.
        try do
          cancel(request, "await timed out")
        rescue
          _error in Error -> :ok
        catch
          :exit, _ -> :ok
        end

        raise Error,
          code: :timeout,
          message: "#{request.method} timed out",
          details: %{timeout_ms: timeout}
    end
  end

  def await(%ClientRequest{}, _timeout) do
    raise ArgumentError, "an asynchronous client request must be awaited by its owner process"
  end

  @doc "Explicitly cancels an in-flight non-task request."
  def cancel(%ClientRequest{client: %Client{pid: pid}, ref: ref} = request, reason \\ nil)
      when is_binary(reason) or is_nil(reason) do
    case GenServer.call(pid, {:cancel_request, ref, reason}) do
      :ok ->
        if request.owner == self(), do: Process.demonitor(request.monitor, [:flush])
        :ok

      {:error, %Error{} = error} ->
        raise error
    end
  end

  @doc "Returns whether a server-initiated callback has been cancelled."
  def callback_cancelled?(%CallbackContext{client: %Client{pid: pid}} = context) do
    case context.cancellation_ref do
      cancellation_ref when not is_nil(cancellation_ref) ->
        :atomics.get(cancellation_ref, 1) == 1

      nil ->
        GenServer.call(pid, {:callback_cancelled?, context.request_id, context.task_id})
    end
  end

  @doc "Emits progress for a server-initiated callback."
  def report_progress(
        %CallbackContext{client: %Client{pid: pid}} = context,
        progress,
        opts \\ []
      )
      when is_number(progress) and is_list(opts) do
    case GenServer.call(pid, {:report_callback_progress, context, progress, opts}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Requests completion values for a prompt argument or resource-template parameter."
  def complete(client_ref, ref, argument, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    params =
      %{
        "ref" => Map.new(ref),
        "argument" => Map.new(argument)
      }
      |> FastestMCP.Client.Codec.maybe_put(
        "context",
        if(opts[:context_arguments], do: %{"arguments" => Map.new(opts[:context_arguments])})
      )
      |> FastestMCP.Client.Codec.maybe_put_request_meta(opts)

    request(client, "completion/complete", params, :completion, opts)
  end

  @doc "Lists visible tools."
  def list_tools(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    request(client, "tools/list", FastestMCP.Client.Codec.pagination_params(opts), :tools, opts)
  end

  @doc "Lists every visible tool across the server's bounded pagination sequence."
  def list_all_tools(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    Telemetry.with_client_span("tools/list", nil, %{}, fn trace ->
      FastestMCP.Client.Catalog.catalog_snapshot(
        client,
        FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)
      ).tools
    end)
  end

  @doc "Lists visible resources."
  def list_resources(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    request(
      client,
      "resources/list",
      FastestMCP.Client.Codec.pagination_params(opts),
      :resources,
      opts
    )
  end

  @doc "Lists every visible resource across the server's bounded pagination sequence."
  def list_all_resources(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    Telemetry.with_client_span("resources/list", nil, %{}, fn trace ->
      FastestMCP.Client.Interaction.list_all(
        client,
        &list_resources/2,
        "resources/list",
        FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)
      )
    end)
  end

  @doc "Lists visible resource templates."
  def list_resource_templates(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    request(
      client,
      "resources/templates/list",
      FastestMCP.Client.Codec.pagination_params(opts),
      :resource_templates,
      opts
    )
  end

  @doc "Lists every visible resource template across the bounded pagination sequence."
  def list_all_resource_templates(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    Telemetry.with_client_span("resources/templates/list", nil, %{}, fn trace ->
      FastestMCP.Client.Interaction.list_all(
        client,
        &list_resource_templates/2,
        "resources/templates/list",
        FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)
      )
    end)
  end

  @doc "Reads a resource by URI."
  def read_resource(client_ref, uri, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    uri = to_string(uri)

    Telemetry.with_client_span("resources/read", uri, %{}, fn trace ->
      traced_opts = FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)

      params =
        %{"uri" => uri}
        |> FastestMCP.Client.Codec.maybe_put_transport_version(traced_opts[:version])
        |> FastestMCP.Client.Codec.maybe_put_request_meta(traced_opts)

      FastestMCP.Client.Interaction.request_with_mrtr(
        client,
        "resources/read",
        params,
        traced_opts,
        :resource_read
      )
    end)
  end

  @doc "Subscribes the current session to updates for one concrete resource URI."
  def subscribe_resource(client_ref, uri, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    request(
      client,
      "resources/subscribe",
      %{"uri" => to_string(uri)} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Removes one resource subscription from the current session."
  def unsubscribe_resource(client_ref, uri, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    request(
      client,
      "resources/unsubscribe",
      %{"uri" => to_string(uri)} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Lists visible prompts."
  def list_prompts(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    request(
      client,
      "prompts/list",
      FastestMCP.Client.Codec.pagination_params(opts),
      :prompts,
      opts
    )
  end

  @doc "Lists every visible prompt across the server's bounded pagination sequence."
  def list_all_prompts(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    Telemetry.with_client_span("prompts/list", nil, %{}, fn trace ->
      FastestMCP.Client.Interaction.list_all(
        client,
        &list_prompts/2,
        "prompts/list",
        FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)
      )
    end)
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    name = to_string(name)

    Telemetry.with_client_span("prompts/get", name, %{}, fn trace ->
      traced_opts = FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)

      params =
        %{
          "name" => name,
          "arguments" => Map.new(arguments)
        }
        |> FastestMCP.Client.Codec.maybe_put_request_meta(traced_opts)

      FastestMCP.Client.Interaction.request_with_mrtr(
        client,
        "prompts/get",
        params,
        traced_opts,
        :prompt
      )
    end)
  end

  def request(%Client{pid: pid}, method, params, normalizer, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_mode, :span) do
      :propagate_only ->
        context = Keyword.get(opts, :__fastestmcp_trace_context, Telemetry.current_context())

        do_client_request(
          pid,
          method,
          params,
          normalizer,
          FastestMCP.Client.Trace.put_trace_context(opts, context)
        )

      :span ->
        target = FastestMCP.Client.Trace.client_trace_target(method, params)

        Telemetry.with_client_span(method, target, %{}, fn trace ->
          result =
            do_client_request(
              pid,
              method,
              params,
              normalizer,
              FastestMCP.Client.Trace.put_client_trace(opts, trace)
            )

          FastestMCP.Client.Trace.maybe_mark_tool_error(result, trace, method)
          result
        end)
    end
  end

  defp do_client_request(pid, method, params, normalizer, opts) do
    opts = FastestMCP.Deadline.request_options(opts, @default_timeout_ms, method)
    timeout_ms = opts[:timeout_ms]

    case GenServer.call(
           pid,
           {:request, method, params, normalizer, opts},
           FastestMCP.Client.Connection.call_timeout(timeout_ms)
         ) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, %ProtocolError{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp notification(%Client{pid: pid}, method, params, opts) do
    opts = FastestMCP.Deadline.request_options(opts, @default_timeout_ms, method)
    timeout_ms = opts[:timeout_ms]

    case GenServer.call(
           pid,
           {:notification, method, params, opts},
           FastestMCP.Client.Connection.call_timeout(timeout_ms)
         ) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  def send_client_notification(state, method, params, opts) do
    with :ok <- FastestMCP.Client.Connection.validate_connected_transport_options(state, opts) do
      params =
        if state.selected_protocol_version == "2026-07-28" do
          FastestMCP.Client.Codec.put_modern_request_meta(params, state)
        else
          params
        end

      params =
        if state.transport.type == :in_process do
          FastestMCP.Client.Codec.put_stdio_auth_metadata(
            params,
            FastestMCP.Client.Codec.request_auth_input(state, opts),
            true
          )
        else
          params
        end

      message = FastestMCP.Client.Codec.build_notification(method, params)

      protocol_version = state.selected_protocol_version || "2025-11-25"

      case FastestMCP.Schema.validate_protocol(
             protocol_version,
             :client_to_server,
             :notification,
             method,
             message
           ) do
        {:ok, ^message} ->
          case state.transport.type do
            type when type in [:stdio, :in_process] ->
              FastestMCP.Client.Connection.safe_connected_transport_command(
                state.transport,
                message
              )

            :streamable_http ->
              FastestMCP.Client.HTTP.send_notification(message, state, opts)
          end

        {:error, %FastestMCP.Schema.Error{} = error} ->
          {:error,
           %Error{
             code: :invalid_params,
             message: "invalid #{method} notification",
             details: %{violations: error.violations}
           }}
      end
    end
  end
end
