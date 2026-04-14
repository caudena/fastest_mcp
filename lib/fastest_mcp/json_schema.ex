defmodule FastestMCP.JSONSchema do
  @moduledoc """
  Helpers for small JSON Schema operations such as reference detection and dereferencing.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  @local_defs_prefix "#/$defs/"

  @doc "Returns whether the schema contains JSON Schema references."
  def has_ref?(schema) when is_map(schema) do
    schema = stringify_keys(schema)
    has_ref_in_value?(schema)
  end

  def has_ref?(_schema), do: false

  @doc "Dereferences JSON Schema references where supported."
  def dereference_refs(schema) when is_map(schema) do
    schema = schema |> stringify_keys() |> strip_remote_refs()
    defs = Map.get(schema, "$defs", %{})

    resolved =
      if defs_have_cycles?(defs) do
        resolve_root_ref(schema, defs)
      else
        dereference_value(schema, defs, MapSet.new())
      end

    resolved
    |> Map.delete("$defs")
    |> strip_discriminator()
  end

  def dereference_refs(schema), do: schema

  defp resolve_root_ref(schema, defs) do
    case Map.get(schema, "$ref") do
      @local_defs_prefix <> name ->
        base =
          defs
          |> Map.get(name, %{})
          |> dereference_value(defs, MapSet.new([name]))

        schema
        |> Map.delete("$ref")
        |> dereference_value(defs, MapSet.new())
        |> Map.merge(base)

      _other ->
        schema
    end
  end

  defp dereference_value(%{"$ref" => @local_defs_prefix <> name} = schema, defs, visiting) do
    if MapSet.member?(visiting, name) do
      Map.delete(schema, "$ref")
    else
      referenced =
        defs
        |> Map.get(name, %{})
        |> dereference_value(defs, MapSet.put(visiting, name))

      siblings =
        schema
        |> Map.delete("$ref")
        |> dereference_value(defs, visiting)

      Map.merge(referenced, siblings)
    end
  end

  defp dereference_value(schema, defs, visiting) when is_map(schema) do
    Enum.into(schema, %{}, fn {key, value} ->
      {key, dereference_value(value, defs, visiting)}
    end)
  end

  defp dereference_value(schema, defs, visiting) when is_list(schema) do
    Enum.map(schema, &dereference_value(&1, defs, visiting))
  end

  defp dereference_value(value, _defs, _visiting), do: value

  defp has_ref_in_value?(%{"$ref" => _ref}), do: true

  defp has_ref_in_value?(value) when is_map(value) do
    Enum.any?(value, fn {_key, child} -> has_ref_in_value?(child) end)
  end

  defp has_ref_in_value?(value) when is_list(value) do
    Enum.any?(value, &has_ref_in_value?/1)
  end

  defp has_ref_in_value?(_value), do: false

  defp strip_remote_refs(%{"$ref" => ref} = value) when is_binary(ref) do
    if String.starts_with?(ref, "#") do
      Enum.into(value, %{}, fn {key, child} -> {key, strip_remote_refs(child)} end)
    else
      value
      |> Map.delete("$ref")
      |> Enum.into(%{}, fn {key, child} -> {key, strip_remote_refs(child)} end)
    end
  end

  defp strip_remote_refs(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} -> {key, strip_remote_refs(child)} end)
  end

  defp strip_remote_refs(value) when is_list(value) do
    Enum.map(value, &strip_remote_refs/1)
  end

  defp strip_remote_refs(value), do: value

  defp strip_discriminator(%{"discriminator" => _discriminator} = value)
       when is_map_key(value, "anyOf") or is_map_key(value, "oneOf") do
    value
    |> Map.delete("discriminator")
    |> Enum.into(%{}, fn {key, child} -> {key, strip_discriminator(child)} end)
  end

  defp strip_discriminator(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} ->
      if key in ["default", "const", "examples", "enum"] do
        {key, child}
      else
        {key, strip_discriminator(child)}
      end
    end)
  end

  defp strip_discriminator(value) when is_list(value) do
    Enum.map(value, &strip_discriminator/1)
  end

  defp strip_discriminator(value), do: value

  defp defs_have_cycles?(defs) when map_size(defs) == 0, do: false

  defp defs_have_cycles?(defs) do
    edges =
      Enum.into(defs, %{}, fn {name, definition} ->
        {name, collect_local_refs(definition, MapSet.new())}
      end)

    states = %{}
    Enum.any?(Map.keys(defs), &cycle_from?(&1, defs, edges, states))
  end

  defp cycle_from?(node, defs, edges, states) do
    do_cycle_from?(node, defs, edges, states) |> elem(0)
  end

  defp do_cycle_from?(node, defs, edges, states) do
    case Map.get(states, node, :unvisited) do
      :visiting ->
        {true, states}

      :done ->
        {false, states}

      :unvisited ->
        states = Map.put(states, node, :visiting)

        Enum.reduce_while(Map.get(edges, node, MapSet.new()), {false, states}, fn neighbor,
                                                                                  {_found, states} ->
          if Map.has_key?(defs, neighbor) do
            case do_cycle_from?(neighbor, defs, edges, states) do
              {true, states} -> {:halt, {true, states}}
              {false, states} -> {:cont, {false, states}}
            end
          else
            {:cont, {false, states}}
          end
        end)
        |> case do
          {true, states} -> {true, states}
          {false, states} -> {false, Map.put(states, node, :done)}
        end
    end
  end

  defp collect_local_refs(%{"$ref" => @local_defs_prefix <> name} = value, acc) do
    value
    |> Map.delete("$ref")
    |> collect_local_refs(MapSet.put(acc, name))
  end

  defp collect_local_refs(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {_key, child}, acc -> collect_local_refs(child, acc) end)
  end

  defp collect_local_refs(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_local_refs/2)
  end

  defp collect_local_refs(_value, acc), do: acc

  defp stringify_keys(%_{} = struct), do: stringify_keys(Map.from_struct(struct))

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} -> {to_string(key), stringify_keys(child)} end)
  end

  defp stringify_keys(value) when is_list(value) do
    Enum.map(value, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value
end
