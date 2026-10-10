defmodule FastestMCP.ComponentStore do
  @moduledoc false
  # Registration rules over any map holding the four component collections
  # (`tools`, `resources`, `resource_templates`, `prompts`): server definitions,
  # local providers, and the component manager's state all store components
  # through these functions.

  require Logger

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup

  @policies [:error, :warn, :ignore, :replace]

  def policy!(policy) when policy in @policies, do: policy

  def policy!(other) do
    raise ArgumentError,
          "on_duplicate must be one of #{inspect(@policies)}, got #{inspect(other)}"
  end

  def list(holder, kind), do: Map.fetch!(holder, Component.collection(kind))

  def candidates(holder, kind, identifier, version),
    do: holder |> list(kind) |> Lookup.candidates(identifier, version)

  # Returns `{:ok, holder}` once stored, `{:ignore, existing}` when the
  # (validated) `policy` keeps an existing definition with the same identifier
  # and version, or `{:error, %ArgumentError{}}` for a rejected definition.
  def put(holder, component, policy) do
    collection = Component.collection(component)
    components = Map.fetch!(holder, collection)

    with :ok <- check_version_mixing(components, component) do
      case Enum.find_index(components, &same_key?(&1, component)) do
        nil ->
          {:ok, Map.replace!(holder, collection, components ++ [component])}

        index when policy == :ignore ->
          {:ignore, Enum.at(components, index)}

        index ->
          with :ok <- report_duplicate(policy, component) do
            components = List.replace_at(components, index, component)
            {:ok, Map.replace!(holder, collection, components)}
          end
      end
    end
  end

  # A nil version selects every version of the identifier.
  def delete(holder, kind, identifier, version) do
    collection = Component.collection(kind)

    {removed, kept} =
      holder
      |> Map.fetch!(collection)
      |> Enum.split_with(&matches?(&1, identifier, version))

    {removed, Map.replace!(holder, collection, kept)}
  end

  def update(holder, kind, identifier, version, fun) do
    collection = Component.collection(kind)

    {components, updated} =
      holder
      |> Map.fetch!(collection)
      |> Enum.map_reduce([], fn component, updated ->
        if matches?(component, identifier, version) do
          component = fun.(component)
          {component, [component | updated]}
        else
          {component, updated}
        end
      end)

    {Enum.reverse(updated), Map.replace!(holder, collection, components)}
  end

  defp matches?(component, identifier, version) do
    Component.identifier(component) == identifier and Lookup.version_matches?(component, version)
  end

  defp same_key?(left, right) do
    Component.identifier(left) == Component.identifier(right) and
      Component.version(left) == Component.version(right)
  end

  defp check_version_mixing(components, component) do
    versioned? = not is_nil(Component.version(component))

    if Enum.any?(
         components,
         &(Component.identifier(&1) == Component.identifier(component) and
             is_nil(Component.version(&1)) == versioned?)
       ) do
      order = if versioned?, do: "versioned and unversioned", else: "unversioned and versioned"

      {:error,
       ArgumentError.exception("#{Component.describe(component)} cannot mix #{order} definitions")}
    else
      :ok
    end
  end

  defp report_duplicate(:replace, _component), do: :ok

  defp report_duplicate(:warn, component),
    do: Logger.warning(duplicate_message(component) <> "; replacing existing definition")

  defp report_duplicate(:error, component),
    do: {:error, ArgumentError.exception(duplicate_message(component))}

  defp duplicate_message(component) do
    case Component.version(component) do
      nil -> "#{Component.describe(component)} is already defined without a version"
      version -> "#{Component.describe(component)} version #{inspect(version)} is already defined"
    end
  end
end
