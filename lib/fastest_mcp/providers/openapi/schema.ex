defmodule FastestMCP.Providers.OpenAPI.Schema do
  @moduledoc false
  alias FastestMCP.Schema.Policy

  # Only these positions contain schemas. Annotation/default/enum values are
  # application data, even when they contain keys called "$ref" or "nullable".
  @maps ~w(properties patternProperties $defs definitions dependentSchemas dependencies)
  @lists ~w(allOf anyOf oneOf prefixItems)
  @single ~w(items additionalItems additionalProperties unevaluatedProperties unevaluatedItems contains propertyNames not if then else contentSchema)
  @object_keys ~w(type properties required title description example examples deprecated additionalProperties)

  def prepare(nil, _spec, _opts), do: nil
  def prepare(schema, _spec, _opts) when is_boolean(schema), do: schema

  def prepare(schema, spec, opts) when is_map(schema) do
    stats = check_source!(schema, opts)
    schema = normalize(schema, spec)
    bucket = unused_bucket(Map.get(schema, "$defs", %{}), 0)
    {schema, names} = rewrite(schema, bucket)

    definitions =
      collect(
        :queue.from_list(Enum.sort(MapSet.to_list(names))),
        MapSet.new(),
        %{},
        spec,
        bucket,
        opts,
        stats.encoded_bytes
      )

    schema =
      if map_size(definitions) == 0 do
        schema
      else
        Map.update(schema, "$defs", %{bucket => definitions}, &Map.put(&1, bucket, definitions))
      end

    # A binding's schema is embedded under the generated tool's properties.
    # Give its local references a resource boundary so they still refer to the
    # binding's root, not to the generated tool root.
    if scoped?(schema) and not Map.has_key?(schema, "$id") do
      {:ok, digest} = FastestMCP.Schema.digest(schema)
      Map.put(schema, "$id", "urn:fastestmcp:openapi:" <> digest)
    else
      schema
    end
  end

  def view(schema, spec), do: view(schema, spec, MapSet.new())

  defp view(%{"$ref" => "#/components/schemas/" <> _ = ref} = schema, spec, seen) do
    if MapSet.member?(seen, ref) do
      schema
    else
      target = lookup!(spec, ref)
      target = view(target, spec, MapSet.put(seen, ref))
      siblings = Map.delete(schema, "$ref")

      cond do
        siblings == %{} ->
          target

        plain_object?(target) and plain_object?(Map.put_new(siblings, "type", "object")) and
          not Map.has_key?(target, "additionalProperties") and
            not Map.has_key?(siblings, "additionalProperties") ->
          properties =
            Map.merge(target["properties"] || %{}, siblings["properties"] || %{}, fn _, a, b ->
              if a == b, do: a, else: %{"allOf" => [a, b]}
            end)

          target
          |> Map.merge(siblings)
          |> Map.put("properties", properties)
          |> Map.put(
            "required",
            Enum.uniq((target["required"] || []) ++ (siblings["required"] || []))
          )

        true ->
          schema
      end
    end
  end

  defp view(schema, _spec, _seen), do: schema

  def plain_object?(%{"type" => "object", "properties" => properties} = schema)
      when is_map(properties) and map_size(properties) > 0 do
    Enum.all?(Map.keys(schema), &(&1 in @object_keys)) and
      Map.get(schema, "additionalProperties", false) == false and
      not local_refs?(schema)
  end

  def plain_object?(_schema), do: false

  # OpenAPI Reference Objects are not JSON Schema references: dereference only
  # the object itself, without recursively expanding its embedded schemas.
  def reference!(object, spec), do: reference!(object, spec, MapSet.new())

  defp reference!(%{"$ref" => ref} = object, spec, seen) do
    if MapSet.member?(seen, ref),
      do: raise(ArgumentError, "cyclic OpenAPI reference #{inspect(ref)}")

    target = lookup!(spec, ref)
    target = reference!(target, spec, MapSet.put(seen, ref))
    Map.merge(target, Map.delete(object, "$ref"))
  end

  defp reference!(object, _spec, _seen) when is_map(object), do: object

  defp reference!(_object, _spec, _seen),
    do: raise(ArgumentError, "OpenAPI reference must resolve to an object")

  defp lookup!(spec, ref) do
    with true <- is_binary(ref) and String.starts_with?(ref, "#/"),
         {:ok, %{kind: :pointer, arg: path}} <- JSV.Ref.parse(ref, :root),
         {:ok, target} <- walk_pointer(spec, path),
         true <- is_map(target) or is_boolean(target) do
      target
    else
      _ -> raise ArgumentError, "unresolved OpenAPI reference #{inspect(ref)}"
    end
  end

  defp walk_pointer(value, []), do: {:ok, value}

  defp walk_pointer(value, [key | rest]) when is_map(value) do
    with {:ok, child} <- Map.fetch(value, key), do: walk_pointer(child, rest)
  end

  defp walk_pointer(value, [key | rest]) when is_list(value) do
    with {index, ""} when index >= 0 <- Integer.parse(key),
         {:ok, child} <- Enum.fetch(value, index),
         do: walk_pointer(child, rest)
  end

  defp walk_pointer(_value, _path), do: :error

  defp normalize(schema, spec) do
    legacy? = not String.starts_with?(Map.get(spec, "openapi", "3.0"), "3.1")

    map_schemas(schema, fn node ->
      if legacy? and node["nullable"] == true do
        node = Map.delete(node, "nullable")

        case Map.get(node, "type") do
          type when is_binary(type) -> Map.put(node, "type", [type, "null"])
          types when is_list(types) -> Map.put(node, "type", Enum.uniq(types ++ ["null"]))
          _ -> %{"anyOf" => [node, %{"type" => "null"}]}
        end
      else
        node
      end
    end)
  end

  defp rewrite(schema, bucket) do
    {rewritten, names} =
      walk_schemas(
        schema,
        MapSet.new(),
        fn node, names ->
          Enum.reduce(["$ref", "$dynamicRef"], {node, names}, fn key, {node, names} ->
            case Map.get(node, key) do
              "#/components/schemas/" <> _ = ref ->
                %{arg: ["components", "schemas", name | tail]} = JSV.Ref.parse!(ref, :root)
                rewritten = JSV.Ref.pointer!(["$defs", bucket, name | tail], :root) |> to_string()
                {Map.put(node, key, rewritten), MapSet.put(names, name)}

              _ ->
                {node, names}
            end
          end)
        end,
        true
      )

    {rewritten, names}
  end

  defp collect(queue, seen, definitions, spec, bucket, opts, bytes) do
    case :queue.out(queue) do
      {:empty, _} ->
        definitions

      {{:value, name}, queue} ->
        if MapSet.member?(seen, name) do
          collect(queue, seen, definitions, spec, bucket, opts, bytes)
        else
          ref = JSV.Ref.pointer!(["components", "schemas", name], :root) |> to_string()
          source = lookup!(spec, ref)
          stats = check_source!(source, opts)
          bytes = bytes + stats.encoded_bytes

          if MapSet.size(seen) >=
               Keyword.get(opts, :max_resolved_resources, Policy.default(:max_resolved_resources)) or
               bytes > Keyword.get(opts, :max_schema_bytes, Policy.default(:max_schema_bytes)) do
            raise FastestMCP.Schema.Error,
              phase: :compile,
              message: "OpenAPI reference closure exceeds configured schema limits"
          end

          {schema, discovered} = source |> normalize(spec) |> rewrite(bucket)
          queue = Enum.reduce(Enum.sort(MapSet.to_list(discovered)), queue, &:queue.in/2)

          collect(
            queue,
            MapSet.put(seen, name),
            Map.put(definitions, name, schema),
            spec,
            bucket,
            opts,
            bytes
          )
        end
    end
  end

  defp check_source!(schema, opts) do
    case Policy.check(schema, opts) do
      {:ok, stats} ->
        stats

      {:error, reason} ->
        raise FastestMCP.Schema.Error, phase: :compile, message: Policy.message(reason)
    end
  end

  defp unused_bucket(definitions, index) do
    name = if index == 0, do: "__openapi", else: "__openapi_#{index}"
    if Map.has_key?(definitions, name), do: unused_bucket(definitions, index + 1), else: name
  end

  defp scoped?(schema) do
    {_, found} =
      walk_schemas(schema, false, fn node, found ->
        {node, found or Map.has_key?(node, "$ref") or Map.has_key?(node, "$dynamicRef")}
      end)

    found
  end

  defp local_refs?(schema) do
    {_, found} =
      walk_schemas(schema, false, fn node, found ->
        ref = Map.get(node, "$ref", "")

        {node,
         found or Map.has_key?(node, "$id") or
           (is_binary(ref) and String.starts_with?(ref, "#") and
              not String.starts_with?(ref, "#/components/schemas/"))}
      end)

    found
  end

  defp map_schemas(schema, fun),
    do: elem(walk_schemas(schema, nil, fn node, acc -> {fun.(node), acc} end), 0)

  defp walk_schemas(schema, acc, fun, skip_resources \\ false, root? \\ true)
  defp walk_schemas(%{"$id" => _} = schema, acc, _fun, true, false), do: {schema, acc}

  defp walk_schemas(schema, acc, fun, skip_resources, _root?) when is_map(schema) do
    {schema, acc} =
      Enum.reduce(schema, {%{}, acc}, fn {key, value}, {out, acc} ->
        {value, acc} =
          cond do
            key in @maps and is_map(value) ->
              Enum.reduce(value, {%{}, acc}, fn {name, child}, {out, acc} ->
                {child, acc} = walk_schemas(child, acc, fun, skip_resources, false)
                {Map.put(out, name, child), acc}
              end)

            key in @lists and is_list(value) ->
              Enum.map_reduce(value, acc, &walk_schemas(&1, &2, fun, skip_resources, false))

            key in @single and is_list(value) ->
              Enum.map_reduce(value, acc, &walk_schemas(&1, &2, fun, skip_resources, false))

            key in @single ->
              walk_schemas(value, acc, fun, skip_resources, false)

            true ->
              {value, acc}
          end

        {Map.put(out, key, value), acc}
      end)

    fun.(schema, acc)
  end

  defp walk_schemas(schema, acc, _fun, _skip_resources, _root?), do: {schema, acc}
end
