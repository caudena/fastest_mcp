defmodule FastestMCP.ComponentVisibility do
  @moduledoc false

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.ComponentManager
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime

  @version_comparisons %{eq: [:eq], gt: [:gt], gte: [:eq, :gt], lt: [:lt], lte: [:eq, :lt]}

  def enable(server_name, opts \\ []), do: update_server_rules(server_name, :enable, opts)
  def disable(server_name, opts \\ []), do: update_server_rules(server_name, :disable, opts)

  def reset(server_name),
    do: update_rules(server_name, fn _rules -> [] end, [:tools, :resources, :prompts])

  def server_rules(server_name),
    do: server_name |> normalize_server_name() |> Registry.visibility_rules()

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

  defp normalize_rule(action, opts) when action in [:enable, :disable] and is_list(opts) do
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

  defp component_families(opts) when is_list(opts) do
    case normalize_component_types(opts[:components]) do
      nil ->
        [:tools, :resources, :prompts]

      kinds ->
        kinds |> Enum.map(&Component.family/1) |> Enum.uniq() |> Enum.sort()
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
    rules = normalize_rules(action, opts)
    update_rules(server_name, &(&1 ++ rules), component_families(opts))
  end

  defp update_rules(server_name, update, families) do
    server_name = normalize_server_name(server_name)

    with {:ok, runtime} <- ServerRuntime.fetch_running(server_name) do
      if ComponentManager.update_visibility_rules(runtime.component_manager, update) == :changed do
        EventBus.emit(
          runtime.event_bus,
          server_name,
          [:components, :changed],
          %{count: length(families)},
          %{families: families}
        )
      end

      :ok
    end
  catch
    :exit, reason -> {:error, Error.from_exit(reason)}
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
    matches_component_selector?(rule.components, Component.kind(component))
  end

  defp visibility_rule_matches?(rule, component) do
    if has_visibility_criteria?(rule) do
      identifier = Component.identifier(component)
      key = Component.key(component)
      version = Component.version(component) && to_string(Component.version(component))
      tags = Map.get(component, :tags, MapSet.new())
      component_type = Component.kind(component)

      matches_selector?(rule.names, identifier) and
        matches_selector?(rule.keys, key) and
        matches_version_selector?(rule.version, version) and
        matches_component_selector?(rule.components, component_type) and
        matches_tag_selector?(rule.tags, tags)
    else
      false
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

  defp matches_version_selector?(selector, version) do
    Enum.all?(selector, fn
      {_operator, nil} ->
        true

      {operator, expected} ->
        Lookup.compare_versions(version, expected) in @version_comparisons[operator]
    end)
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

    normalized =
      Map.new(@version_comparisons, fn {operator, _orders} ->
        value = selector[operator]
        {operator, value && to_string(value)}
      end)

    if Enum.all?(normalized, fn {_operator, value} -> is_nil(value) end) do
      raise ArgumentError,
            "visibility version selectors must include at least one of :eq, :gt, :gte, :lt, or :lte"
    end

    normalized
  end

  defp normalize_version_selector(selector) do
    %{eq: to_string(selector), gt: nil, gte: nil, lt: nil, lte: nil}
  end

  defp normalize_optional_string_set(nil), do: nil

  defp normalize_optional_string_set(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp normalize_component_types(nil), do: nil

  defp normalize_component_types(values),
    do: values |> List.wrap() |> MapSet.new(&Component.kind!/1)
end
