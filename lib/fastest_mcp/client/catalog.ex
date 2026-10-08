defmodule FastestMCP.Client.Catalog do
  @moduledoc false
  alias FastestMCP.Client.Paginator
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Schema

  @default_timeout_ms 5_000

  @doc false
  def catalog_snapshot(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    mode = Keyword.get(opts, :cache, :use)

    unless mode in [:use, :refresh, :bypass],
      do: raise(ArgumentError, "cache must be :use, :refresh, or :bypass")

    deadline = FastestMCP.Deadline.from_options(opts, @default_timeout_ms)
    catalog = ensure_tool_catalog!(client, deadline, opts, mode)
    validate_limits!(catalog, opts)

    %{
      client: client,
      generation: catalog.generation,
      tools: catalog.raw,
      expires_at_ms: catalog.expires_at_ms
    }
  end

  @doc false
  def catalog_revision(client_ref) do
    GenServer.call(FastestMCP.Client.Connection.pin_client!(client_ref).pid, :catalog_revision)
  end

  def tool_descriptor!(client, name, version, deadline, trace_opts) do
    catalog = ensure_tool_catalog!(client, deadline, trace_opts)

    case ToolCatalog.lookup(catalog, name, version) do
      {:ok, descriptor} ->
        descriptor

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise ProtocolError.new(
                "tools/list",
                :server_to_client,
                :response,
                error.violations,
                nil
              )

      {:error, reason} ->
        raise Error,
          code: :invalid_request,
          message: "server advertised an unusable descriptor for tool #{inspect(name)}",
          details: %{tool: name, version: version, reason: inspect(reason)}

      :error ->
        raise Error,
          code: :method_not_found,
          message: "server did not advertise tool #{inspect(name)}",
          details: %{tool: name, version: version}
    end
  end

  defp ensure_tool_catalog!(client, deadline, trace_opts, mode \\ :use) do
    if FastestMCP.Client.Codec.authentication_options(trace_opts) != [] do
      {generation, schema_options} = GenServer.call(client.pid, :catalog_configuration)

      case load_tool_catalog(
             client,
             generation,
             schema_options,
             deadline,
             Keyword.put(trace_opts, :cache, :bypass)
           ) do
        {:ok, catalog} -> catalog
        {:error, error} -> raise error
      end
    else
      shared_tool_catalog!(client, deadline, trace_opts, mode)
    end
  end

  defp shared_tool_catalog!(client, deadline, trace_opts, mode) do
    timeout = remaining_timeout!(deadline, "tools/list")

    response =
      try do
        GenServer.call(
          client.pid,
          {:ensure_tool_catalog, mode},
          FastestMCP.Client.Connection.call_timeout(timeout)
        )
      catch
        :exit, {:timeout, _call} ->
          raise Error, code: :timeout, message: "tools/list catalog discovery timed out"
      end

    case response do
      {:ready, %ToolCatalog{} = catalog} ->
        catalog

      {:load, generation, schema_options} ->
        result =
          load_tool_catalog(
            client,
            generation,
            schema_options,
            deadline,
            Keyword.put(trace_opts, :cache, mode)
          )

        case GenServer.call(client.pid, {:install_tool_catalog, generation, result}) do
          {:ready, %ToolCatalog{} = catalog} -> catalog
          {:error, exception} when is_exception(exception) -> raise exception
          :stale -> ensure_tool_catalog!(client, deadline, trace_opts, mode)
        end

      {:error, exception} when is_exception(exception) ->
        raise exception
    end
  end

  defp load_tool_catalog(client, generation, schema_options, deadline, trace_opts) do
    fetch_page = fn cursor ->
      opts =
        trace_opts
        |> FastestMCP.Client.Codec.authentication_options()
        |> Keyword.merge(
          Keyword.take(trace_opts, [:__fastestmcp_trace_context, :__fastestmcp_client_trace])
        )
        |> Keyword.put(:__fastestmcp_trace_mode, :propagate_only)
        |> Keyword.put(:cache, Keyword.get(trace_opts, :cache, :use))
        |> Keyword.put(:timeout_ms, remaining_timeout!(deadline, "tools/list"))

      opts =
        if is_nil(cursor) do
          opts
        else
          opts
          |> Keyword.put(:cursor, cursor)
          |> Keyword.put(:cache, :bypass)
        end

      FastestMCP.Client.Interaction.capture_page(fn ->
        FastestMCP.Client.Requests.list_tools(client, opts)
      end)
    end

    case Paginator.fetch_all_with_meta(
           fetch_page,
           Keyword.take(trace_opts, [:max_pages, :max_items])
         ) do
      {:ok, %{items: tools, ttl_ms: ttl_ms, page_count: page_count}} ->
        FastestMCP.Client.Trace.annotate_pagination_trace(trace_opts, page_count, length(tools))

        {:ok,
         %{ToolCatalog.build(tools, generation, schema_options, ttl_ms) | page_count: page_count}}

      {:error, %Error{} = error} ->
        {:error, tool_catalog_pagination_error(error)}

      {:error, exception} when is_exception(exception) ->
        {:error, exception}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "tools/list catalog pagination failed",
           details: %{reason: inspect(reason)}
         }}
    end
  rescue
    exception -> {:error, exception}
  end

  defp tool_catalog_pagination_error(%Error{details: %{cursor: _cursor}} = error),
    do: %{error | message: "tools/list returned a repeated cursor"}

  defp tool_catalog_pagination_error(%Error{details: %{max_pages: _max_pages}} = error),
    do: %{error | message: "tools/list exceeded the client catalog page limit"}

  defp tool_catalog_pagination_error(%Error{details: %{max_items: _max_items}} = error),
    do: %{error | message: "tools/list exceeded the client catalog item limit"}

  defp tool_catalog_pagination_error(error), do: error

  def validate_tool_arguments!(descriptor, arguments) do
    case Schema.validate(descriptor.input_validator, arguments) do
      {:ok, ^arguments} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :invalid_params,
          message: "tool arguments do not match the advertised inputSchema",
          details: %{tool: descriptor.name, violations: error.violations}
    end
  end

  def http_parameter_headers!(client, descriptor, arguments) do
    if FastestMCP.Client.Connection.client_transport_type(client) == :streamable_http do
      encode_http_parameter_headers!(descriptor, arguments)
    else
      %{}
    end
  end

  defp encode_http_parameter_headers!(descriptor, arguments) do
    case HTTPHeaders.encode(descriptor.http_headers, arguments) do
      {:ok, headers} ->
        headers

      {:error, reason} ->
        raise Error,
          code: :invalid_params,
          message: "tool arguments cannot be represented in the declared HTTP headers",
          details: %{tool: descriptor.name, reason: reason}
    end
  end

  def validate_tool_task_mode!(client, descriptor, task_augmented?, modern_protocol?) do
    capabilities = FastestMCP.Client.Connection.capabilities(client)

    task_capability? =
      Protocol.capability?(capabilities, ["tasks", "requests", "tools", "call"])

    cond do
      modern_protocol? ->
        :ok

      task_augmented? and not task_capability? ->
        raise Error,
          code: :bad_request,
          message: "server did not advertise task-augmented tool calls"

      task_augmented? and descriptor.task_support == :forbidden ->
        raise Error,
          code: :method_not_found,
          message: "tool #{inspect(descriptor.name)} does not support task execution"

      not task_augmented? and descriptor.task_support == :required ->
        raise Error,
          code: :method_not_found,
          message: "tool #{inspect(descriptor.name)} requires task execution"

      true ->
        :ok
    end
  end

  def validate_tool_output!(descriptor, result),
    do: validate_tool_output_validator!(descriptor.output_validator, descriptor.name, result)

  def validate_tool_output_validator!(nil, _name, _result), do: :ok

  def validate_tool_output_validator!(validator, name, %{"isError" => true} = result) do
    if Map.has_key?(result, "structuredContent") do
      validate_structured_tool_output!(validator, name, result["structuredContent"])
    else
      :ok
    end
  end

  def validate_tool_output_validator!(validator, name, result) do
    if Map.has_key?(result, "structuredContent") do
      validate_structured_tool_output!(validator, name, result["structuredContent"])
    else
      raise ProtocolError.new(
              "tools/call",
              :server_to_client,
              :response,
              [%{path: "/structuredContent", message: "required by advertised outputSchema"}],
              nil
            )
    end
  end

  defp validate_structured_tool_output!(validator, name, structured_content) do
    case Schema.validate(validator, structured_content) do
      {:ok, ^structured_content} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise ProtocolError.new(
                "tools/call",
                :server_to_client,
                :response,
                Enum.map(error.violations, &Map.put_new(&1, :tool, name)),
                nil
              )
    end
  end

  defdelegate remaining_timeout!(deadline, operation), to: FastestMCP.Deadline, as: :remaining!

  defp validate_limits!(catalog, opts) do
    for {key, count, default} <- [
          {:max_pages, catalog.page_count, 256},
          {:max_items, length(catalog.raw), 100_000}
        ] do
      limit = Keyword.get(opts, key, default)

      unless is_integer(limit) and limit > 0,
        do: raise(ArgumentError, "#{key} must be a positive integer")

      if count > limit,
        do:
          raise(Error,
            code: :overloaded,
            message: "tools/list exceeded #{key}",
            details: %{key => limit}
          )
    end

    :ok
  end

  def normalize_schema_options!(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, "schema_options must be a keyword list"
    end
  end

  def normalize_schema_options!(other) do
    raise ArgumentError, "schema_options must be a keyword list, got: #{inspect(other)}"
  end

  def maybe_put_task_output_validator(entry, nil), do: entry

  def maybe_put_task_output_validator(entry, validator),
    do: Map.put(entry, :output_validator, validator)
end
