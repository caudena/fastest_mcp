defmodule FastestMCP.Client.Catalog do
  @moduledoc false
  # The connected client's tool catalog from the caller: complete tools/list
  # snapshots, loaded by one caller while concurrent callers wait (see
  # `FastestMCP.Client.Connection.Catalog`), the descriptor a tools/call is
  # validated against, and tool argument and result validation. A per-call
  # identity loads a private catalog.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client
  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.Connection
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Requests
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Schema

  @default_timeout_ms 5_000

  def snapshot(client_ref, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts),
         do: snapshot(client, opts, nil)
  end

  def snapshot(%Client{} = client, opts, trace) do
    mode = Keyword.get(opts, :cache, :use)

    unless mode in [:use, :refresh, :bypass],
      do: raise(ArgumentError, "cache must be :use, :refresh, or :bypass")

    deadline = Deadline.from_options(opts, @default_timeout_ms)

    with {:ok, catalog} <- fetch(client, :all, mode, deadline, opts, trace),
         :ok <- check_limits(catalog, opts) do
      {:ok,
       %{
         client: client,
         generation: catalog.generation,
         tools: catalog.raw,
         expires_at_ms: catalog.expires_at_ms
       }}
    end
  end

  def revision(client_ref) do
    with {:ok, client} <- Connection.pin(client_ref),
         do: Connection.call(client, :catalog_revision)
  end

  # The advertised descriptor of one tool, with the connection snapshot.
  def descriptor(client, name, version, deadline, opts, trace) do
    with {:ok, {lookup, snapshot}} <- fetch(client, {name, version}, :use, deadline, opts, trace) do
      case lookup do
        {:ok, descriptor} ->
          {:ok, descriptor, snapshot}

        {:error, %Schema.Error{} = error} ->
          {:error,
           ProtocolError.new("tools/list", :server_to_client, :response, error.violations)}

        {:error, reason} ->
          {:error,
           %Error{
             code: :invalid_request,
             message: "server advertised an unusable descriptor for tool #{inspect(name)}",
             details: %{tool: name, version: version, reason: inspect(reason)}
           }}

        :error ->
          {:error,
           %Error{
             code: :method_not_found,
             message: "server did not advertise tool #{inspect(name)}",
             details: %{tool: name, version: version}
           }}
      end
    end
  end

  # `select` (:all or `{name, version}`) of the connection's catalog; this
  # caller loads it when the connection makes it the loader.
  defp fetch(client, select, mode, deadline, opts, trace) do
    mode = if Auth.options(opts) == [], do: mode, else: :private

    with {:ok, timeout} <- Deadline.check(deadline, "tools/list") do
      call_timeout = Connection.call_timeout(timeout)

      case Connection.call(client, {:tool_catalog, mode, select}, call_timeout) do
        {:load, generation, schema_options, snapshot} when mode == :private ->
          opts = Keyword.put(opts, :cache, :bypass)

          with {:ok, tools} <- load(client, generation, schema_options, deadline, opts, trace),
               do: {:ok, selection(tools, select, snapshot)}

        {:load, generation, schema_options, _snapshot} ->
          opts = Keyword.put(opts, :cache, mode)
          result = load(client, generation, schema_options, deadline, opts, trace)

          case Connection.call(client, {:install_tool_catalog, generation, result, select}) do
            :stale -> fetch(client, select, mode, deadline, opts, trace)
            reply -> reply
          end

        reply ->
          reply
      end
    end
  end

  defp selection(tools, :all, _snapshot), do: tools

  defp selection(tools, {name, version}, snapshot),
    do: {ToolCatalog.lookup(tools, name, version), snapshot}

  defp load(client, generation, schema_options, deadline, opts, trace) do
    opts = Keyword.merge(Auth.options(opts), Keyword.take(opts, [:cache, :max_pages, :max_items]))

    case Requests.pages(client, "tools/list", :tools, opts, deadline, trace) do
      {:ok, %{items: tools, ttl_ms: ttl_ms, page_count: page_count}} ->
        {:ok,
         %{ToolCatalog.build(tools, generation, schema_options, ttl_ms) | page_count: page_count}}

      {:error, error} ->
        {:error, pagination_error(error)}
    end
  end

  defp pagination_error(%Error{details: %{cursor: _cursor}} = error),
    do: %{error | message: "tools/list returned a repeated cursor"}

  defp pagination_error(%Error{details: %{max_pages: _max_pages}} = error),
    do: %{error | message: "tools/list exceeded the client catalog page limit"}

  defp pagination_error(%Error{details: %{max_items: _max_items}} = error),
    do: %{error | message: "tools/list exceeded the client catalog item limit"}

  defp pagination_error(error), do: error

  # A cached catalog may have been loaded under larger limits.
  defp check_limits(catalog, opts) do
    [max_pages: {catalog.page_count, 256}, max_items: {length(catalog.raw), 100_000}]
    |> Enum.find_value(:ok, fn {key, {count, default}} ->
      limit = Keyword.get(opts, key, default)

      unless is_integer(limit) and limit > 0,
        do: raise(ArgumentError, "#{key} must be a positive integer")

      if count > limit do
        message = "tools/list exceeded #{key}"
        {:error, %Error{code: :overloaded, message: message, details: %{key => limit}}}
      end
    end)
  end

  ## Validation

  def validate_arguments(descriptor, arguments) do
    case Schema.validate(descriptor.input_validator, arguments) do
      {:ok, ^arguments} ->
        :ok

      {:error, %Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "tool arguments do not match the advertised inputSchema",
           details: %{tool: descriptor.name, violations: error.violations}
         }}
    end
  end

  # Streamable HTTP mirrors annotated arguments in Mcp-Param headers.
  def http_parameter_headers(%{transport: :streamable_http}, descriptor, arguments) do
    case HTTPHeaders.encode(descriptor.http_headers, arguments) do
      {:ok, headers} ->
        {:ok, headers}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "tool arguments cannot be represented in the declared HTTP headers",
           details: %{tool: descriptor.name, reason: reason}
         }}
    end
  end

  def http_parameter_headers(_snapshot, _descriptor, _arguments), do: {:ok, %{}}

  # Legacy task augmentation must match the server's and the tool's support;
  # modern tasks are server-directed.
  def validate_task_mode(%{protocol_version: modern()}, _descriptor, _task_requested?),
    do: :ok

  def validate_task_mode(snapshot, descriptor, task_requested?) do
    capable? = Protocol.capability?(snapshot.capabilities, ["tasks", "requests", "tools", "call"])

    cond do
      task_requested? and not capable? ->
        {:error,
         %Error{code: :bad_request, message: "server did not advertise task-augmented tool calls"}}

      task_requested? and descriptor.task_support == :forbidden ->
        {:error,
         %Error{
           code: :method_not_found,
           message: "tool #{inspect(descriptor.name)} does not support task execution"
         }}

      not task_requested? and descriptor.task_support == :required ->
        {:error,
         %Error{
           code: :method_not_found,
           message: "tool #{inspect(descriptor.name)} requires task execution"
         }}

      true ->
        :ok
    end
  end

  # A result is checked against the advertised outputSchema; an error result
  # need not carry structured content.
  def validate_output(nil, _name, _result), do: :ok

  def validate_output(validator, name, result) do
    case result do
      %{"structuredContent" => structured} ->
        case Schema.validate(validator, structured) do
          {:ok, ^structured} ->
            :ok

          {:error, %Schema.Error{} = error} ->
            violations = Enum.map(error.violations, &Map.put_new(&1, :tool, name))
            {:error, ProtocolError.new("tools/call", :server_to_client, :response, violations)}
        end

      %{"isError" => true} ->
        :ok

      _result ->
        violation = %{path: "/structuredContent", message: "required by advertised outputSchema"}
        {:error, ProtocolError.new("tools/call", :server_to_client, :response, [violation])}
    end
  end
end
