defmodule FastestMCP.Transport.Engine.Components do
  @moduledoc false
  # Component methods of `Transport.Engine`: list, call, read, get, complete,
  # and resource subscriptions, plus the wire form of component results.

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Apps
  alias FastestMCP.Auth
  alias FastestMCP.BackgroundTask
  alias FastestMCP.Component
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Session
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Serializer

  @list_keys %{
    tool: :tools,
    resource: :resources,
    resource_template: :resourceTemplates,
    prompt: :prompts
  }

  def handle(runtime, %Request{method: "completion/complete"} = request, opts) do
    with {:ok, ref} <- Request.fetch_param(request, "ref"),
         {:ok, argument} <- Request.fetch_param(request, "argument"),
         {:ok, completion} <-
           OperationPipeline.complete(
             runtime.server.name,
             ref,
             argument,
             Keyword.merge(opts,
               wire: true,
               context_arguments: get_in(request.payload, ["context", "arguments"]) || %{}
             )
           ) do
      {:ok,
       %{
         completion:
           %{"values" => Map.get(completion, :values, [])}
           |> maybe_put("total", Map.get(completion, :total))
           |> maybe_put("hasMore", Map.get(completion, :has_more))
       }}
    end
  end

  def handle(runtime, %Request{method: method} = request, _opts)
      when method in ["resources/subscribe", "resources/unsubscribe"] do
    with {:ok, uri} <- Request.fetch_param(request, "uri"),
         {:ok, session_id} <- subscription_session(runtime, request) do
      result =
        if method == "resources/subscribe",
          do: Session.subscribe_resource(runtime.server.name, session_id, uri),
          else: Session.unsubscribe_resource(runtime.server.name, session_id, uri)

      case result do
        :ok -> {:ok, %{}}
        {:error, :not_found} -> {:error, Error.not_found(:session, session_id)}
      end
    end
  end

  def handle(runtime, %Request{method: method} = request, opts) do
    case Component.list_kind(method) do
      nil -> call(runtime, Component.call_kind(method), request, opts)
      kind -> list(runtime, kind, request, opts)
    end
  end

  # The wire form of a result of a `kind` component, nil if unknown.
  def serialize(:tool, _target, tool, value, request, opts),
    do: Serializer.tool_result(value, tool, serializer_opts(request, opts))

  def serialize(:resource, uri, resource, value, request, opts) do
    result =
      Serializer.resource_result(
        uri,
        resource && resource.mime_type,
        value,
        serializer_opts(request, opts)
      )

    if apps_negotiated?(opts) and ui_uri?(uri) and not valid_apps_contents?(result, uri) do
      raise Error,
        code: :internal_error,
        message: "MCP Apps resource handler returned an invalid UI content envelope"
    end

    result
  end

  def serialize(:prompt, _target, _prompt, value, _request, _opts),
    do: Serializer.prompt_result(value)

  # The component a call of `target` would run for this request, or nil.
  def visible_component(runtime, kind, target, opts) do
    case OperationPipeline.visible_component(runtime.server.name, kind, target, opts) do
      {:ok, component} -> component
      {:error, _error} -> nil
    end
  end

  # Binds a wire cursor to everything that decides what a listing contains,
  # for the caller that `context` authenticated.
  def pagination_fingerprint(runtime, %Request{} = request, opts, %Context{} = context) do
    %{
      authorization: Auth.authorization_partition(context),
      session_id: request.session_id,
      audience: Keyword.get(opts, :audience, :model),
      version: Keyword.get(opts, :version),
      visibility_filter: %{
        method: request.method,
        params: Map.drop(request.payload, ["cursor", "pageSize", "_meta"]),
        server_rules: ComponentVisibility.server_rules(runtime.server.name),
        session_rules: ComponentVisibility.session_rules(context)
      }
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp call(runtime, kind, request, opts) do
    with {:ok, target} <- Request.fetch_param(request, Component.call_param(kind)),
         {:ok, opts} <- call_opts(kind, request, opts),
         {:ok, %Operation{result: result, component: component}} <-
           OperationPipeline.invoke(
             runtime.server.name,
             kind,
             target,
             call_arguments(kind, request),
             opts
           ) do
      call_result(result, request, &serialize(kind, target, component, &1, request, opts))
    end
  end

  # A call picks a version with `_meta.fastestmcp.version`.
  defp call_opts(kind, request, opts) do
    opts = maybe_put(opts, :version, Request.component_version(request))
    opts = if kind == :tool, do: put_header_validator(opts, request), else: opts

    case request do
      %Request{task_request: true, profile: profile} when profile != :modern ->
        with {:ok, session_id} <- task_session_id(request),
             do: {:ok, Keyword.put(opts, :session_id, session_id)}

      _other ->
        {:ok, opts}
    end
  end

  defp call_arguments(:resource, _request), do: %{}
  defp call_arguments(_kind, request), do: Map.get(request.payload, "arguments", %{})

  defp task_session_id(request) do
    with :error <- Request.explicit_session_id(request),
         do: Engine.error(:bad_request, "task requests require an explicit session_id")
  end

  defp call_result(%InputRequiredResult{} = result, %Request{profile: :modern} = request, _fun) do
    with :ok <-
           InputRequiredResult.validate_client_capabilities(
             result,
             Request.client_capabilities(request)
           ),
         do: {:ok, InputRequiredResult.to_map(result)}
  end

  defp call_result(%InputRequiredResult{}, request, _fun) do
    {:error,
     Error.internal(
       "input_required is not valid for #{request.method} under #{request.protocol_version}"
     )}
  end

  defp call_result(%BackgroundTask{} = task, request, _fun),
    do: {:ok, TaskWire.create_task_result(task, protocol_version: request.protocol_version)}

  defp call_result(result, _request, fun), do: Engine.wire(fn -> fun.(result) end)

  # MCP 2026 tools may bind arguments to `Mcp-Param-*` headers, which must match.
  defp put_header_validator(
         opts,
         %Request{profile: :modern, transport: :streamable_http} = request
       ) do
    headers = Map.get(request.request_metadata, :headers, %{})

    Keyword.put(opts, :before_component_execute, fn component, operation ->
      with {:ok, annotations} <- HTTPHeaders.annotations(component.input_schema),
           :ok <- HTTPHeaders.validate(annotations, operation.arguments, headers) do
        :ok
      else
        {:error, mismatch} ->
          {:error,
           %Error{
             code: :header_mismatch,
             message: "Mcp-Param header does not match the tool arguments",
             details: Map.put(Map.new(mismatch), :jsonrpc_code, -32_020)
           }}
      end
    end)
  end

  defp put_header_validator(opts, _request), do: opts

  defp subscription_session(runtime, %Request{session_id: session_id} = request)
       when is_binary(session_id) and session_id != "" do
    with {:ok, _context} <-
           OperationPipeline.request_context(runtime, Engine.session_opts(request, session_id)),
         do: {:ok, session_id}
  end

  defp subscription_session(_runtime, _request),
    do: Engine.error(:bad_request, "resource subscriptions require an explicit session_id")

  # The listing authenticates its caller once: the lookups that follow use
  # the identity it authenticated.
  defp list(runtime, kind, request, opts) do
    with {:ok, page, context} <-
           OperationPipeline.wire_list_page(runtime.server.name, kind, opts,
             secret: runtime.signing_secret.value,
             scope: request.method,
             fingerprint: &pagination_fingerprint(runtime, request, opts, &1),
             cursor: Map.get(request.payload, "cursor")
           ),
         opts = Engine.authenticated_opts(opts, context),
         {:ok, items} <- list_items(runtime, kind, page.items, request, opts) do
      {:ok,
       %{Map.fetch!(@list_keys, kind) => Enum.map(items, &list_item(kind, &1, request, opts))}
       |> maybe_put(:nextCursor, page.next_cursor)}
    end
  end

  # Modern tools whose header annotations are invalid are not listed, and every
  # MCP Apps UI resource a listed tool links to must be readable.
  defp list_items(runtime, :tool, tools, request, opts) do
    tools =
      if request.profile == :modern,
        do: Enum.filter(tools, &match?({:ok, _}, HTTPHeaders.annotations(&1[:input_schema]))),
        else: tools

    if apps_negotiated?(opts) and
         tools
         |> Enum.map(&Apps.resource_uri(Map.get(&1, :meta, %{})))
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq()
         |> Enum.any?(&(not apps_resource?(runtime, &1, opts))) do
      {:error, Error.internal("MCP Apps tool references an unavailable UI resource")}
    else
      {:ok, tools}
    end
  end

  defp list_items(_runtime, _kind, items, _request, _opts), do: {:ok, items}

  defp apps_resource?(runtime, uri, opts) do
    resource = visible_component(runtime, :resource, uri, opts)
    is_map(resource) and ui_uri?(uri) and Map.get(resource, :mime_type) == Apps.mime_type()
  end

  defp list_item(:tool, tool, request, opts),
    do:
      with_apps_meta(
        Serializer.tool_metadata(tool, protocol_version: request.protocol_version),
        opts
      )

  defp list_item(:resource, resource, _request, opts),
    do: with_apps_meta(Serializer.resource_metadata(resource), opts)

  defp list_item(:resource_template, template, _request, opts),
    do: with_apps_meta(Serializer.resource_template_metadata(template), opts)

  defp list_item(:prompt, prompt, _request, _opts), do: Serializer.prompt_metadata(prompt)

  defp with_apps_meta(wire, opts) do
    Map.update(
      wire,
      "_meta",
      %{},
      &Apps.filter_meta(&1, client_capabilities(opts), server_extensions(opts))
    )
  end

  # `result` is in wire form.
  defp valid_apps_contents?(%{"contents" => [_ | _] = contents}, uri),
    do: Enum.all?(contents, &valid_apps_content?(&1, to_string(uri)))

  defp valid_apps_contents?(_result, _uri), do: false

  defp valid_apps_content?(%{"uri" => uri, "mimeType" => mime_type} = content, uri),
    do: mime_type == Apps.mime_type() and is_binary(content["text"]) != is_binary(content["blob"])

  defp valid_apps_content?(_content, _uri), do: false

  defp ui_uri?(uri), do: String.starts_with?(to_string(uri), "ui://")

  defp apps_negotiated?(opts),
    do: Apps.negotiated?(client_capabilities(opts), server_extensions(opts))

  defp serializer_opts(request, opts) do
    [
      protocol_version: request.protocol_version,
      client_capabilities: client_capabilities(opts),
      server_extensions: server_extensions(opts)
    ]
  end

  defp client_capabilities(opts), do: Keyword.get(opts, :client_capabilities, %{})
  defp server_extensions(opts), do: Keyword.get(opts, :server_extensions, %{})
end
