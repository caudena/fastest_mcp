defmodule FastestMCP.Client.Requests do
  @moduledoc false
  # Client→server requests. An operation validates its options and pins its
  # client once, builds a `%FastestMCP.Client.Spec{}` per request, and sends
  # it synchronously (`run/2`) or as a request owned by the caller (`start/2`,
  # `await/2`, `cancel/2`). Results are tagged tuples.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.Catalog
  alias FastestMCP.Client.Connection
  alias FastestMCP.Client.Mrtr
  alias FastestMCP.Client.Options
  alias FastestMCP.Client.Paginator
  alias FastestMCP.Client.Request, as: ClientRequest
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Trace
  alias FastestMCP.Client.Wire
  alias FastestMCP.Deadline
  alias FastestMCP.Error

  @default_timeout_ms 5_000

  ## Plumbing

  def operation(client_ref, opts) do
    opts = Options.operation!(opts)
    with {:ok, client} <- Connection.pin(client_ref), do: {:ok, client, opts}
  end

  defp operate(client_ref, opts, fun) do
    with {:ok, client, opts} <- operation(client_ref, opts), do: fun.(client, opts)
  end

  def run(%Client{} = client, %Spec{} = spec) do
    with :ok <- Spec.check(spec),
         {:ok, remaining} <- Deadline.check(spec.deadline, spec.method),
         do: Connection.call(client, {:request, spec}, Connection.call_timeout(remaining))
  end

  def start(%Client{pid: pid} = client, %Spec{} = spec) do
    with :ok <- Spec.check(spec),
         {:ok, remaining} <- Deadline.check(spec.deadline, spec.method),
         {:ok, ref, request_id, task_augmented?} <-
           Connection.call(
             client,
             {:request_async, spec, self()},
             Connection.call_timeout(remaining)
           ) do
      {:ok,
       %ClientRequest{
         client: client,
         ref: ref,
         request_id: request_id,
         method: spec.method,
         owner: self(),
         monitor: Process.monitor(pid),
         task_augmented: task_augmented?
       }}
    end
  end

  # One request in its own client span.
  def request(%Client{} = client, method, params, normalizer, opts) do
    Trace.span(method, Trace.target(method, params), fn trace ->
      result = run(client, Spec.new(method, params, normalizer, opts, trace))
      Trace.mark_tool_error(result, trace, method)
      result
    end)
  end

  # Every page of a list method within one deadline; later pages bypass the
  # response cache.
  def pages(client, method, normalizer, opts, deadline, trace) do
    fetch = fn cursor ->
      opts = if cursor, do: Keyword.merge(opts, cursor: cursor, cache: :bypass), else: opts
      spec = Spec.new(method, Wire.pagination(opts), normalizer, opts, trace)
      run(client, %{spec | deadline: deadline})
    end

    with {:ok, result} <-
           Paginator.fetch_all_with_meta(fetch, Keyword.take(opts, [:max_pages, :max_items])) do
      Trace.annotate(trace, %{
        "mcp.pagination.page.count" => result.page_count,
        "mcp.pagination.item.count" => length(result.items)
      })

      {:ok, result}
    end
  end

  ## Requests

  def request(client_ref, method, params, opts)
      when is_binary(method) and is_map(params) and is_list(opts),
      do: operate(client_ref, opts, &request(&1, method, Options.wire_map(params), :identity, &2))

  def request_async(client_ref, method, params, opts)
      when is_binary(method) and is_map(params) and is_list(opts) do
    params = Options.wire_map(params)

    operate(client_ref, opts, fn client, opts ->
      trace = Trace.start(method, Trace.target(method, params))
      spec = %{Spec.new(method, params, :identity, opts, trace) | end_trace?: true}

      with {:error, error} <- start(client, spec) do
        Trace.finish(trace, {:error, error})
        {:error, error}
      end
    end)
  end

  def await(%ClientRequest{owner: owner} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_client_response, ref, reply} when ref == request.ref ->
        Process.demonitor(request.monitor, [:flush])
        reply

      {:DOWN, monitor, :process, _pid, reason} when monitor == request.monitor ->
        {:error, Connection.exit_error(reason)}
    after
      timeout ->
        Process.demonitor(request.monitor, [:flush])
        # Completion or the connection's request timer can win this race.
        _ = cancel(request, "await timed out")

        {:error,
         %Error{
           code: :timeout,
           message: "#{request.method} timed out",
           details: %{timeout_ms: timeout}
         }}
    end
  end

  def await(%ClientRequest{}, _timeout) do
    raise ArgumentError, "an asynchronous client request must be awaited by its owner process"
  end

  def cancel(%ClientRequest{client: client, ref: ref} = request, reason)
      when is_binary(reason) or is_nil(reason) do
    with :ok <- Connection.call(client, {:cancel_request, ref, reason}) do
      if request.owner == self(), do: Process.demonitor(request.monitor, [:flush])
      :ok
    end
  end

  def listen(client_ref, filter, opts) do
    params = %{"notifications" => Map.new(filter)}
    opts = Keyword.put(opts, :timeout_ms, :infinity)
    request_async(client_ref, "subscriptions/listen", params, opts)
  end

  ## Negotiation

  def initialize(client_ref, params, opts) do
    params = Options.wire_map(params)

    operate(client_ref, opts, fn client, opts ->
      with :ok <- Connection.call(client, :begin_initialize) do
        result =
          with {:ok, result} <- request(client, "initialize", params, :initialize, opts),
               :ok <- notify(client, "notifications/initialized", opts),
               :ok <- Connection.call(client, :finish_initialize),
               do: {:ok, result}

        with {:error, _error} <- result, do: fail(client, :fail_initialize, result)
      end
    end)
  end

  def discover(client_ref, opts) do
    operate(client_ref, opts, fn client, opts ->
      with {:ok, token} <- Connection.call(client, :begin_discover) do
        opts = Keyword.put(opts, :deadline, Deadline.from_options(opts, @default_timeout_ms))

        result =
          with {:ok, result} <- discover_request(client, opts, 1),
               :ok <- Connection.call(client, {:finish_discover, token, result}),
               do: {:ok, result}

        with {:error, _error} <- result, do: fail(client, {:fail_discover, token}, result)
      end
    end)
  end

  defp fail(client, message, result) do
    _ = Connection.call(client, message)
    result
  end

  # A server that rejects the requested version but supports MCP 2026-07-28
  # gets one more attempt.
  defp discover_request(client, opts, retries) do
    with {:error, %Error{code: :unsupported_protocol_version, details: %{} = details} = error} <-
           request(client, "server/discover", %{}, :identity, opts) do
      if retries > 0 and modern() in List.wrap(details["supported"]),
        do: discover_request(client, opts, retries - 1),
        else: {:error, error}
    end
  end

  defp notify(client, method, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = opts |> Deadline.from_options(timeout) |> Deadline.cap(timeout)

    with {:ok, remaining} <- Deadline.check(deadline, method) do
      Connection.call(
        client,
        {:notification, method, %{}, Keyword.put(opts, :deadline, deadline)},
        Connection.call_timeout(remaining)
      )
    end
  end

  ## Operations

  def ping(client_ref, opts),
    do: operate(client_ref, opts, &request(&1, "ping", %{}, :identity, &2))

  def set_log_level(client_ref, level, opts) do
    params = %{"level" => log_level!(level)}

    operate(client_ref, opts, fn client, opts ->
      with {:ok, _result} <-
             request(client, "logging/setLevel", Wire.put_meta(params, opts), :identity, opts),
           do: :ok
    end)
  end

  # A callback whose connection is gone is cancelled.
  def callback_cancelled?(%CallbackContext{client: client, cancellation_ref: nil} = context) do
    message = {:callback_cancelled?, context.request_id, context.task_id}
    Connection.call(client, message) != false
  end

  def callback_cancelled?(%CallbackContext{client: client, cancellation_ref: ref}),
    do: :atomics.get(ref, 1) == 1 or not Process.alive?(client.pid)

  def report_progress(%CallbackContext{client: client} = context, progress, opts)
      when is_number(progress) do
    opts = Options.operation!(opts)
    Connection.call(client, {:report_callback_progress, context, progress, opts})
  end

  def complete(client_ref, ref, argument, opts) do
    operate(client_ref, opts, fn client, opts ->
      params =
        %{"ref" => Map.new(ref), "argument" => Map.new(argument)}
        |> FastestMCP.Util.maybe_put(
          "context",
          if(opts[:context_arguments], do: %{"arguments" => Map.new(opts[:context_arguments])})
        )
        |> Wire.put_meta(opts)

      request(client, "completion/complete", params, :completion, opts)
    end)
  end

  def list_tools(client_ref, opts), do: list(client_ref, "tools/list", :tools, opts)

  def list_resources(client_ref, opts),
    do: list(client_ref, "resources/list", :resources, opts)

  def list_prompts(client_ref, opts), do: list(client_ref, "prompts/list", :prompts, opts)

  def list_resource_templates(client_ref, opts),
    do: list(client_ref, "resources/templates/list", :resource_templates, opts)

  defp list(client_ref, method, normalizer, opts),
    do: operate(client_ref, opts, &request(&1, method, Wire.pagination(&2), normalizer, &2))

  def list_all_tools(client_ref, opts) do
    operate(client_ref, opts, fn client, opts ->
      Trace.span("tools/list", nil, fn trace ->
        with {:ok, snapshot} <- Catalog.snapshot(client, opts, trace), do: {:ok, snapshot.tools}
      end)
    end)
  end

  def list_all_resources(client_ref, opts),
    do: list_all(client_ref, "resources/list", :resources, opts)

  def list_all_prompts(client_ref, opts),
    do: list_all(client_ref, "prompts/list", :prompts, opts)

  def list_all_resource_templates(client_ref, opts),
    do: list_all(client_ref, "resources/templates/list", :resource_templates, opts)

  defp list_all(client_ref, method, normalizer, opts) do
    operate(client_ref, opts, fn client, opts ->
      deadline = Deadline.from_options(opts, @default_timeout_ms)
      opts = Keyword.delete(opts, :cursor)

      Trace.span(method, nil, fn trace ->
        with {:ok, %{items: items}} <- pages(client, method, normalizer, opts, deadline, trace),
             do: {:ok, items}
      end)
    end)
  end

  def read_resource(client_ref, uri, opts) do
    uri = to_string(uri)

    operate(client_ref, opts, fn client, opts ->
      params = %{"uri" => uri} |> Wire.put_version(opts[:version]) |> Wire.put_meta(opts)

      Trace.span("resources/read", uri, fn trace ->
        Mrtr.run(client, Spec.new("resources/read", params, :resource_read, opts, trace), opts)
      end)
    end)
  end

  def render_prompt(client_ref, name, arguments, opts) do
    name = to_string(name)

    operate(client_ref, opts, fn client, opts ->
      params = Wire.put_meta(%{"name" => name, "arguments" => Map.new(arguments)}, opts)

      Trace.span("prompts/get", name, fn trace ->
        Mrtr.run(client, Spec.new("prompts/get", params, :prompt, opts, trace), opts)
      end)
    end)
  end

  def subscribe_resource(client_ref, uri, opts),
    do: resource_subscription(client_ref, "resources/subscribe", uri, opts)

  def unsubscribe_resource(client_ref, uri, opts),
    do: resource_subscription(client_ref, "resources/unsubscribe", uri, opts)

  defp resource_subscription(client_ref, method, uri, opts) do
    params = %{"uri" => to_string(uri)}

    operate(client_ref, opts, fn client, opts ->
      with {:ok, _result} <- request(client, method, Wire.put_meta(params, opts), :identity, opts),
           do: :ok
    end)
  end

  defp log_level!(level) when is_atom(level), do: log_level!(Atom.to_string(level))

  defp log_level!(level)
       when level in ~w(debug info notice warning error critical alert emergency),
       do: level

  defp log_level!(level) do
    raise ArgumentError,
          "log level must be debug, info, notice, warning, error, critical, alert, or emergency, got #{inspect(level)}"
  end
end
