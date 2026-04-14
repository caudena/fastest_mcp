defmodule FastestMCP.ComponentVisibility do
  @moduledoc false

  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.ServerRuntime

  @table :fastest_mcp_component_visibility

  @component_family_map %{
    tool: :tools,
    resource: :resources,
    resource_template: :resources,
    prompt: :prompts
  }

  def enable(server_name, opts \\ []), do: update_server_rules(server_name, :enable, opts)
  def disable(server_name, opts \\ []), do: update_server_rules(server_name, :disable, opts)

  def reset(server_name) do
    server_name = normalize_server_name(server_name)
    ensure_runtime!(server_name)
    ensure_table!()

    case :ets.lookup(@table, server_name) do
      [] ->
        :ok

      _existing ->
        :ets.delete(@table, server_name)
        broadcast_change(server_name, [:tools, :resources, :prompts])
        :ok
    end
  end

  def delete(server_name) do
    ensure_table!()
    :ets.delete(@table, normalize_server_name(server_name))
    :ok
  end

  def server_rules(server_name) do
    server_name = normalize_server_name(server_name)
    ensure_table!()

    case :ets.lookup(@table, server_name) do
      [{^server_name, rules}] when is_list(rules) -> rules
      _other -> []
    end
  end

  def session_rules(%Context{} = context) do
    context
    |> Context.get_state({:fastest_mcp, :visibility_rules}, [])
    |> List.wrap()
  end

  def normalize_rules(action, opts) when action in [:enable, :disable] and is_list(opts) do
    base_opts = Keyword.delete(opts, :only)
    rule = normalize_rule(action, base_opts)

    if Keyword.get(opts, :only, false) and action == :enable do
      [disable_all_rule(base_opts), rule]
    else
      [rule]
    end
  end

  def normalize_rule(action, opts) when action in [:enable, :disable] and is_list(opts) do
    %{
      action: action,
      names: normalize_optional_string_set(opts[:names]),
      keys: normalize_optional_string_set(opts[:keys]),
      version: normalize_version_selector(opts[:version]),
      tags: normalize_optional_string_set(opts[:tags]),
      components: normalize_component_types(opts[:components]),
      match_all: Keyword.get(opts, :match_all, false)
    }
  end

  def component_families(opts) when is_list(opts) do
    case normalize_component_types(opts[:components]) do
      nil ->
        [:tools, :resources, :prompts]

      components ->
        components
        |> Enum.map(&Map.fetch!(@component_family_map, &1))
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  def apply_server_rules(nil, _server_name), do: nil

  def apply_server_rules(component, server_name) do
    apply_rules(component, server_rules(server_name), :server)
  end

  def apply_session_rules(nil, _context), do: nil

  def apply_session_rules(component, %Context{} = context) do
    apply_rules(component, session_rules(context), :session)
  end

  defp update_server_rules(server_name, action, opts) do
    server_name = normalize_server_name(server_name)
    ensure_runtime!(server_name)
    ensure_table!()

    next_rules =
      server_rules(server_name) ++ normalize_rules(action, opts)

    :ets.insert(@table, {server_name, next_rules})
    broadcast_change(server_name, component_families(opts))
    :ok
  end

  defp apply_rules(component, rules, scope) when is_list(rules) do
    Enum.reduce(rules, component, fn rule, current ->
      if visibility_rule_matches?(rule, current) do
        apply_rule(rule, current, scope)
      else
        current
      end
    end)
  end

  defp apply_rule(%{action: :enable}, component, :server) do
    component
    |> set_enabled(true)
    |> put_policy_state(:global_visibility_disabled, false)
  end

  defp apply_rule(%{action: :disable}, component, :server) do
    component
    |> set_enabled(false)
    |> put_policy_state(:global_visibility_disabled, true)
  end

  defp apply_rule(%{action: :enable}, component, :session) do
    if global_visibility_disabled?(component) do
      component
    else
      set_enabled(component, true)
    end
  end

  defp apply_rule(%{action: :disable}, component, :session) do
    set_enabled(component, false)
  end

  defp visibility_rule_matches?(%{match_all: true} = rule, component) do
    matches_component_selector?(rule.components, Component.type(component))
  end

  defp visibility_rule_matches?(rule, component) do
    if not has_visibility_criteria?(rule) do
      false
    else
      identifier = Component.identifier(component)
      key = Component.key(component)
      version = Component.version(component) && to_string(Component.version(component))
      tags = Map.get(component, :tags, MapSet.new())
      component_type = Component.type(component)

      matches_selector?(rule.names, identifier) and
        matches_selector?(rule.keys, key) and
        matches_version_selector?(rule.version, version) and
        matches_component_selector?(rule.components, component_type) and
        matches_tag_selector?(rule.tags, tags)
    end
  end

  defp has_visibility_criteria?(rule) do
    not is_nil(rule.names) or
      not is_nil(rule.keys) or
      not is_nil(rule.version) or
      not is_nil(rule.tags) or
      not is_nil(rule.components)
  end

  defp set_enabled(component, value), do: %{component | enabled: value}

  defp global_visibility_disabled?(component) do
    component
    |> Map.get(:policy_state, %{})
    |> Map.get(:global_visibility_disabled, false)
  end

  defp put_policy_state(component, key, value) do
    policy_state =
      component
      |> Map.get(:policy_state, %{})
      |> Map.new()
      |> Map.put(key, value)

    %{component | policy_state: policy_state}
  end

  defp matches_selector?(nil, _value), do: true
  defp matches_selector?(%MapSet{} = values, value), do: value in values
  defp matches_selector?(expected, value), do: expected == value

  defp matches_version_selector?(nil, _value), do: true
  defp matches_version_selector?(_selector, nil), do: false

  defp matches_version_selector?(%{} = selector, version) do
    satisfies_eq?(version, selector) and
      satisfies_gt?(version, selector) and
      satisfies_gte?(version, selector) and
      satisfies_lt?(version, selector) and
      satisfies_lte?(version, selector)
  end

  defp matches_version_selector?(expected, value), do: matches_selector?(expected, value)

  defp satisfies_eq?(_version, %{eq: nil}), do: true

  defp satisfies_eq?(version, %{eq: expected}),
    do: Component.compare_versions(version, expected) == :eq

  defp satisfies_gt?(_version, %{gt: nil}), do: true

  defp satisfies_gt?(version, %{gt: expected}),
    do: Component.compare_versions(version, expected) == :gt

  defp satisfies_gte?(_version, %{gte: nil}), do: true

  defp satisfies_gte?(version, %{gte: expected}) do
    Component.compare_versions(version, expected) in [:eq, :gt]
  end

  defp satisfies_lt?(_version, %{lt: nil}), do: true

  defp satisfies_lt?(version, %{lt: expected}),
    do: Component.compare_versions(version, expected) == :lt

  defp satisfies_lte?(_version, %{lte: nil}), do: true

  defp satisfies_lte?(version, %{lte: expected}) do
    Component.compare_versions(version, expected) in [:eq, :lt]
  end

  defp matches_component_selector?(nil, _component_type), do: true

  defp matches_component_selector?(%MapSet{} = values, component_type),
    do: component_type in values

  defp matches_tag_selector?(nil, _tags), do: true

  defp matches_tag_selector?(%MapSet{} = values, tags) do
    not MapSet.disjoint?(values, tags)
  end

  defp disable_all_rule(opts) do
    %{
      action: :disable,
      names: nil,
      keys: nil,
      version: nil,
      tags: nil,
      components: normalize_component_types(opts[:components]),
      match_all: true
    }
  end

  defp normalize_server_name(server_name), do: to_string(server_name)

  defp normalize_version_selector(nil), do: nil

  defp normalize_version_selector(selector) when is_map(selector) or is_list(selector) do
    selector = Map.new(selector)

    normalized = %{
      eq: normalize_optional_version(Map.get(selector, :eq, Map.get(selector, "eq"))),
      gt: normalize_optional_version(Map.get(selector, :gt, Map.get(selector, "gt"))),
      gte: normalize_optional_version(Map.get(selector, :gte, Map.get(selector, "gte"))),
      lt: normalize_optional_version(Map.get(selector, :lt, Map.get(selector, "lt"))),
      lte: normalize_optional_version(Map.get(selector, :lte, Map.get(selector, "lte")))
    }

    if Enum.any?(normalized, fn {_key, value} -> not is_nil(value) end) do
      normalized
    else
      raise ArgumentError,
            "visibility version selectors must include at least one of :eq, :gt, :gte, :lt, or :lte"
    end
  end

  defp normalize_version_selector(selector) do
    %{eq: to_string(selector), gt: nil, gte: nil, lt: nil, lte: nil}
  end

  defp normalize_optional_version(nil), do: nil
  defp normalize_optional_version(version), do: to_string(version)

  defp normalize_optional_string_set(nil), do: nil

  defp normalize_optional_string_set(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp normalize_component_types(nil), do: nil

  defp normalize_component_types(values) do
    values
    |> List.wrap()
    |> Enum.map(fn
      :tool -> :tool
      :resource -> :resource
      :template -> :resource_template
      :resource_template -> :resource_template
      :prompt -> :prompt
      "tool" -> :tool
      "resource" -> :resource
      "template" -> :resource_template
      "resource_template" -> :resource_template
      "prompt" -> :prompt
      other -> raise ArgumentError, "unsupported component visibility selector #{inspect(other)}"
    end)
    |> MapSet.new()
  end

  defp ensure_runtime!(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, _runtime} ->
        :ok

      {:error, :not_found} ->
        raise Error, code: :not_found, message: "unknown server #{inspect(server_name)}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to fetch server runtime",
          details: %{reason: inspect(reason)}
    end
  end

  defp broadcast_change(server_name, families) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      EventBus.emit(
        runtime.event_bus,
        server_name,
        [:components, :changed],
        %{count: length(families)},
        %{families: families}
      )
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])
        rescue
          ArgumentError -> @table
        end

      _table ->
        @table
    end
  end
end
