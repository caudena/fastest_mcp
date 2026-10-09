defmodule FastestMCP.Component.Lookup do
  @moduledoc false
  # Version ordering and identifier/URI resolution shared by every component
  # source: the runtime index, server definitions, providers, and the
  # component manager. Resource targets are `{:exact | :template, component,
  # captures}`.

  alias FastestMCP.Component
  alias FastestMCP.Components.ResourceTemplate

  def compare_versions(nil, nil), do: :eq
  def compare_versions(nil, _right), do: :lt
  def compare_versions(_left, nil), do: :gt

  def compare_versions(left, right) do
    left = to_string(left)
    right = to_string(right)

    case {Version.parse(left), Version.parse(right)} do
      {{:ok, left_version}, {:ok, right_version}} ->
        Version.compare(left_version, right_version)

      _ ->
        cond do
          left > right -> :gt
          left < right -> :lt
          true -> :eq
        end
    end
  end

  def version_key(nil), do: ""
  def version_key(version), do: to_string(version)

  def version_matches?(_component, nil), do: true
  def version_matches?(component, version), do: Component.version(component) == version

  # Enum.sort/2 is stable, so equal versions keep their source order.
  def sort_by_version_desc(items, version_of \\ &Component.version/1),
    do: Enum.sort(items, &(compare_versions(version_of.(&1), version_of.(&2)) != :lt))

  def sort_targets(targets),
    do: sort_by_version_desc(targets, &Component.version(elem(&1, 1)))

  def candidates(components, identifier, version) do
    components
    |> Enum.filter(&(Component.identifier(&1) == identifier and version_matches?(&1, version)))
    |> sort_by_version_desc()
  end

  def template_targets(templates, uri, version) do
    for template <- templates,
        version_matches?(template, version),
        %{} = captures <- [ResourceTemplate.match(template, uri)],
        do: {:template, template, captures}
  end

  # Exact resources shadow templates; `templates` may be a zero-arity function
  # so sources only list templates when no exact resource matched.
  def resource_targets(resources, templates, uri, version) do
    case candidates(resources, uri, version) do
      [] -> templates |> force() |> template_targets(uri, version)
      exact -> Enum.map(exact, &{:exact, &1, %{}})
    end
  end

  def target_components(targets, kind),
    do: for({^kind, component, _captures} <- targets, do: component)

  defp force(fun) when is_function(fun, 0), do: fun.()
  defp force(list) when is_list(list), do: list
end
