defmodule FastestMCP.OperationPipeline.Resolver do
  @moduledoc false
  # Finds what an operation can see: candidates from the component index and
  # the providers, kept when transforms, visibility rules, authorization, and
  # the negotiated protocol allow them. Lookups pick the highest visible
  # version; listings and pages hold every visible component.

  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.ComponentIndex
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Operation
  alias FastestMCP.Pagination
  alias FastestMCP.Protocol
  alias FastestMCP.Provider
  alias FastestMCP.ResourceSecurity

  require Logger

  # Lookups pass over candidates hidden with these codes to lower versions.
  @hidden_codes [:disabled, :not_visible, :filtered, :forbidden]
  @tool_fold_page_size 128

  # Every visible component of `kind`, sorted by identifier and version.
  def visible_components(server, kind, operation) do
    server.name
    |> ComponentIndex.list(kind)
    |> Kernel.++(
      Enum.flat_map(server.providers, &Provider.Dispatch.list_components(&1, kind, operation))
    )
    |> visible(server, operation)
    |> Enum.sort_by(&{Component.identifier(&1), Component.version(&1) || ""})
  end

  # The first `limit` visible components of `kind` after `after_key`.
  def visible_page(server, kind, operation, after_key, limit) do
    local =
      server.name
      |> ComponentIndex.list(kind)
      |> fallback_page(server, operation, after_key, limit)

    provider_pages =
      Enum.map(server.providers, &provider_page(&1, kind, server, operation, after_key, limit))

    [local | provider_pages]
    |> List.flatten()
    |> Pagination.source_page(after_key, limit)
    |> Map.fetch!(:items)
  end

  # The highest visible version of `target`, or an error.
  def resolve(server, kind, target, operation) do
    case select(candidates(server, kind, target, operation), server, operation) do
      nil -> {:error, Error.not_found(kind, target)}
      selected -> selected
    end
  end

  # `{:ok, {:exact | :template, component, captures}}` for a resource URI, or
  # an error. Exact resources win over templates.
  def resolve_resource(server, uri, operation) do
    provider_targets =
      Enum.flat_map(
        server.providers,
        &Provider.Dispatch.get_resource_target_candidates(&1, uri, operation)
      )

    exact =
      ComponentIndex.candidates(server.name, :resource, uri, operation.version) ++
        Lookup.target_components(provider_targets, :exact)

    selected =
      if exact == [] do
        server.name
        |> ComponentIndex.list(:resource_template)
        |> Lookup.template_targets(uri, operation.version)
        |> Kernel.++(Enum.filter(provider_targets, &(elem(&1, 0) == :template)))
        |> select_template(server, operation)
      else
        with {:ok, component} <- select(exact, server, operation),
             do: {:ok, {:exact, component, %{}}}
      end

    selected || {:error, unknown_resource(uri, operation)}
  end

  # The `uris` that resolve for `operation`; an unexpected error halts.
  def accessible_resource_uris(server, uris, operation) do
    operation = %{operation | component_type: :resource, method: "resources/read"}

    uris
    |> Enum.reduce_while({:ok, []}, fn uri, {:ok, accessible} ->
      case resolve_resource(server, uri, %{operation | target: uri}) do
        {:ok, _target} ->
          {:cont, {:ok, [uri | accessible]}}

        {:error, %Error{code: code}} when code in [:not_found | @hidden_codes] ->
          {:cont, {:ok, accessible}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, accessible} -> {:ok, Enum.reverse(accessible)}
      error -> error
    end
  end

  # `operation` as the model's tools/list: the catalog tool search works on.
  def catalog_operation(%Operation{} = operation) do
    %{
      operation
      | method: "tools/list",
        component_type: :tool,
        target: nil,
        audience: :model,
        component: nil,
        arguments: %{}
    }
  end

  # The visible catalog tools among `names`, in order.
  def visible_tools_named(%Operation{} = operation, names) when is_list(names) do
    server = operation.context.server
    operation = catalog_operation(operation)

    for name <- names,
        {:ok, tool} <- [
          select(candidates(server, :tool, to_string(name), operation), server, operation)
        ],
        do: tool
  end

  # The `names` naming any tool version, visible or not.
  def tool_name_collisions(%Operation{} = operation, names) when is_list(names) do
    server = operation.context.server
    unversioned = %{operation | version: nil}
    Enum.filter(names, &(candidates(server, :tool, to_string(&1), unversioned) != []))
  end

  # Folds `fun` over the visible catalog tools among the first `max_scan`
  # candidates. Returns `{acc, %{scanned: count, truncated: boolean}}`.
  def fold_visible_tools(%Operation{} = operation, max_scan, acc, fun)
      when is_integer(max_scan) and max_scan > 0 and is_function(fun, 2) do
    server = operation.context.server
    operation = catalog_operation(operation)
    state = %{acc: acc, scanned: 0, truncated: false}
    state = fold_tools(server.tools, server, operation, max_scan, state, fun)

    state =
      Enum.reduce_while(server.providers, state, fn provider, state ->
        if state.truncated,
          do: {:halt, state},
          else: {:cont, fold_provider_tools(provider, server, operation, max_scan, state, fun)}
      end)

    {state.acc, Map.take(state, [:scanned, :truncated])}
  end

  defp candidates(server, kind, target, operation) do
    ComponentIndex.candidates(server.name, kind, target, operation.version) ++
      Enum.flat_map(
        server.providers,
        &Provider.Dispatch.get_component_candidates(&1, kind, target, operation)
      )
  end

  # The highest visible version among `candidates`; when none is visible, the
  # first hiding error, or nil without candidates. Other errors halt.
  defp select(candidates, server, operation) do
    candidates
    |> Lookup.sort_by_version_desc()
    |> Enum.reduce_while(nil, fn component, first_error ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, visible} ->
          if negotiated_visible?(visible, operation),
            do: {:halt, {:ok, visible}},
            else: {:cont, first_error}

        {:error, %Error{code: code} = error} when code in @hidden_codes ->
          {:cont, first_error || {:error, error}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
  end

  defp visible(components, server, operation),
    do: Enum.flat_map(components, &List.wrap(visible_one(&1, server, operation)))

  defp visible_one(component, server, operation) do
    case ComponentPolicy.apply_result(server, component, operation) do
      {:ok, visible} -> if negotiated_visible?(visible, operation), do: visible
      {:error, _error} -> nil
    end
  end

  # Legacy clients only see task-required tools they negotiated tasks for.
  defp negotiated_visible?(_component, %{method: "initialize"}), do: true

  defp negotiated_visible?(%Tool{} = tool, operation) do
    is_modern(operation.context.negotiated_protocol_version) or
      tool.task.mode != :required or
      operation.transport == :in_process or
      Protocol.capability?(
        operation.context.server_capabilities,
        ["tasks", "requests", "tools", "call"]
      )
  end

  defp negotiated_visible?(_component, _operation), do: true

  # A page of unpaged `components`. Without server transforms their keys are
  # final, so only the components on the page go through the policy.
  defp fallback_page(components, %{transforms: []} = server, operation, after_key, limit) do
    components
    |> Enum.sort_by(&page_key/1)
    |> Stream.drop_while(&(not is_nil(after_key) and page_key(&1) <= after_key))
    |> Stream.flat_map(&List.wrap(visible_one(&1, server, operation)))
    |> Enum.take(limit)
  end

  defp fallback_page(components, server, operation, after_key, limit) do
    components
    |> visible(server, operation)
    |> Pagination.source_page(after_key, limit)
    |> Map.fetch!(:items)
  end

  defp page_key(component),
    do: component |> Pagination.default_key() |> Pagination.normalize_source_key()

  # The visible components of the provider's source pages. A provider without
  # source pages, or under server transforms (a rename can reorder), is
  # listed whole.
  defp provider_page(provider, kind, server, operation, after_key, limit) do
    paged =
      server.transforms == [] &&
        reduce_pages(provider, kind, operation, after_key, limit, [], fn page, collected ->
          collected = collected ++ visible(page.items, server, operation)
          remaining = limit - length(collected)

          if remaining > 0,
            do: {collected, remaining},
            else: {Enum.take(collected, limit), nil}
        end)

    paged ||
      provider
      |> Provider.Dispatch.list_components(kind, operation)
      |> fallback_page(server, operation, after_key, limit)
  end

  defp fold_provider_tools(provider, server, operation, max_scan, state, fun) do
    # At most `max_scan + 1` pages, so empty pages cannot scan forever.
    reduce_pages(
      provider,
      :tool,
      operation,
      nil,
      scan_limit(state, max_scan),
      {state, max_scan + 1},
      fn page, {state, pages} ->
        state = fold_tools(page.items, server, operation, max_scan, state, fun)

        cond do
          state.truncated or is_nil(page.next_after) -> {{state, pages}, nil}
          pages == 1 -> {{%{state | truncated: true}, 0}, nil}
          true -> {{state, pages - 1}, scan_limit(state, max_scan)}
        end
      end
    )
    |> case do
      {state, _pages} ->
        state

      nil ->
        provider
        |> Provider.Dispatch.list_components(:tool, operation)
        |> fold_tools(server, operation, max_scan, state, fun)
    end
  end

  defp scan_limit(state, max_scan), do: min(@tool_fold_page_size, max_scan - state.scanned)

  # The provider paging loop, nil for a provider that does not page.
  # `fun.(page, acc)` returns `{acc, limit}` to fetch the next page with `limit`
  # components, or `{acc, nil}` to stop.
  defp reduce_pages(provider, kind, operation, after_key, limit, acc, fun) do
    with %{} = page <-
           Provider.Dispatch.list_component_page(provider, kind, after_key, limit, operation) do
      {acc, limit} = fun.(page, acc)

      if limit && page.next_after,
        do: reduce_pages(provider, kind, operation, page.next_after, limit, acc, fun),
        else: acc
    end
  end

  defp fold_tools(candidates, server, operation, max_scan, state, fun) do
    Enum.reduce_while(candidates, state, fn component, state ->
      state = %{state | scanned: state.scanned + 1}

      state =
        with true <- Lookup.version_matches?(component, operation.version),
             %{} = tool <- visible_one(component, server, operation) do
          %{state | acc: fun.(tool, state.acc)}
        else
          _hidden -> state
        end

      if state.scanned >= max_scan,
        do: {:halt, %{state | truncated: true}},
        else: {:cont, state}
    end)
  end

  defp select_template(candidates, server, operation) do
    candidates
    |> Lookup.sort_targets()
    |> Enum.reduce_while(nil, fn {:template, template, _captures}, first_error ->
      case prepare_template(server, template, operation) do
        {:ok, template, captures} ->
          {:halt, {:ok, {:template, template, captures}}}

        {:skip, :security_rejected} ->
          {:halt, nil}

        {:skip, _reason} ->
          {:cont, first_error}

        {:error, %Error{code: code} = error} when code in @hidden_codes ->
          {:cont, first_error || {:error, error}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
  end

  # Transforms can rewrite a template, so it is matched against the URI again
  # before its captures are screened and authorized.
  defp prepare_template(server, template, operation) do
    with {:ok, visible} <- ComponentPolicy.prepare_result(server, template, operation),
         captures when is_map(captures) <- ResourceTemplate.match(visible, operation.target),
         :ok <- screen_captures(server, visible, captures, operation),
         {:ok, authorized} <-
           ComponentPolicy.authorize_result(visible, %{
             operation
             | component: visible,
               captures: captures
           }) do
      {:ok, authorized, captures}
    else
      nil -> {:skip, :no_longer_matches}
      {:error, :resource_security} -> {:skip, :security_rejected}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp screen_captures(server, template, captures, operation) do
    policy =
      case Map.get(template, :resource_security, :inherit) do
        :inherit -> Map.get(server, :resource_security, %ResourceSecurity{})
        policy -> policy
      end

    case ResourceSecurity.screen(captures, policy) do
      :ok ->
        :ok

      {:error, reason, parameter} ->
        metadata = %{
          reason: reason,
          parameter: parameter,
          template: Component.identifier(template)
        }

        Context.emit(operation.context, [:resource_security, :rejected], %{count: 1}, metadata)

        Logger.debug(fn ->
          "resource template parameter rejected by lexical security policy " <>
            inspect(metadata)
        end)

        {:error, :resource_security}
    end
  end

  defp unknown_resource(uri, operation) do
    modern? = is_modern(operation.context.negotiated_protocol_version)

    details =
      maybe_put(
        %{jsonrpc_code: if(modern?, do: -32_602, else: -32_002)},
        :uri,
        if(modern?, do: uri)
      )

    Error.not_found(:resource, uri, details)
  end
end
