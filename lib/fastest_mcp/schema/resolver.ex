defmodule FastestMCP.Schema.Resolver do
  @moduledoc """
  Bounded adapter for explicitly supplied application JSON Schema resolvers.

  Application resolver functions receive one absolute URI and return
  `{:ok, schema}` or `{:error, reason}`. Resolver modules using the
  `JSV.Resolver` contract are accepted as well. Every successfully resolved
  resource is checked against the same source, nesting, reference, dialect,
  and resource-count limits as the root schema.
  """

  @behaviour JSV.Resolver
  alias FastestMCP.Schema.Policy

  @draft_2020_12 "https://json-schema.org/draft/2020-12/schema"
  @default_max_resolved_resources Policy.default(:max_resolved_resources)

  @impl true
  def resolve(uri, opts) when is_binary(uri) and is_list(opts) do
    with {:ok, schema} <- invoke_resolver(uri, Keyword.get(opts, :resolver)),
         {:ok, normalized} <- normalize_remote_schema(uri, schema, opts) do
      {:normal, normalized}
    end
  rescue
    error -> {:error, {:resolver_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:resolver_failure, kind}}
  end

  def resolve(uri, _opts), do: {:error, {:invalid_remote_schema_uri, uri}}

  @doc false
  def normalize_remote_schema(uri, schema, opts)
      when is_binary(uri) and (is_map(schema) or is_boolean(schema)) and is_list(opts) do
    with {:ok, normalized} <- normalize(schema),
         :ok <- validate_source(normalized, opts),
         {:ok, dialect} <- validate_dialect(normalized, opts),
         :ok <- validate_definition(normalized, dialect),
         :ok <- claim_resource(uri, opts) do
      {:ok, wrap_boolean(uri, normalized)}
    end
  end

  def normalize_remote_schema(_uri, _schema, _opts),
    do: {:error, :remote_schema_must_be_an_object_or_boolean}

  defp invoke_resolver(uri, resolver) when is_function(resolver, 1) do
    normalize_resolver_result(resolver.(uri))
  end

  defp invoke_resolver(uri, {module, resolver_opts}) when is_atom(module) do
    normalize_resolver_result(module.resolve(uri, resolver_opts))
  end

  defp invoke_resolver(uri, module) when is_atom(module) do
    normalize_resolver_result(module.resolve(uri, []))
  end

  defp invoke_resolver(_uri, resolver), do: {:error, {:invalid_resolver, resolver_kind(resolver)}}

  defp normalize_resolver_result({kind, schema})
       when kind in [:ok, :normal] and (is_map(schema) or is_boolean(schema)),
       do: {:ok, schema}

  defp normalize_resolver_result({:error, reason}), do: {:error, reason}

  defp normalize_resolver_result(other),
    do: {:error, {:invalid_resolver_result, resolver_result_kind(other)}}

  defp normalize(schema) do
    {:ok, JSV.Schema.normalize(schema)}
  rescue
    _error -> {:error, :invalid_remote_schema}
  end

  defp validate_dialect(schema, opts) when is_boolean(schema) do
    normalize_dialect(Keyword.get(opts, :default_dialect, @draft_2020_12))
  end

  defp validate_dialect(schema, opts) do
    case Map.get(schema, "$schema", Map.get(schema, :"$schema")) do
      nil ->
        normalize_dialect(Keyword.get(opts, :default_dialect, @draft_2020_12))

      value when is_binary(value) ->
        normalize_dialect(value)

      _other ->
        {:error, :invalid_remote_schema_dialect}
    end
  end

  defp normalize_dialect(value) do
    case Policy.normalize_dialect(value) do
      {:ok, dialect} -> {:ok, dialect}
      {:error, :invalid_dialect} -> {:error, :invalid_remote_schema_dialect}
      {:error, _} -> {:error, :unsupported_remote_schema_dialect}
    end
  end

  defp validate_definition(schema, dialect) do
    case FastestMCP.Schema.validate_schema_definition(schema, dialect) do
      :ok -> :ok
      {:error, %FastestMCP.Schema.Error{}} -> {:error, :invalid_remote_schema_definition}
    end
  end

  defp validate_source(schema, opts) do
    case Policy.check(schema, opts) do
      {:ok, _stats} -> :ok
      {:error, :not_json} -> {:error, :remote_schema_is_not_json_compatible}
      {:error, {:invalid_limit, key, _}} -> {:error, {:invalid_remote_schema_limit, key}}
      {:error, {:exceeded, :max_depth, _, _}} -> {:error, :remote_schema_is_too_deep}
      {:error, {:exceeded, :max_schema_bytes, _, _}} -> {:error, :remote_schema_too_large}
      {:error, {:exceeded, :max_refs, _, _}} -> {:error, :remote_schema_has_too_many_references}
    end
  end

  defp claim_resource(uri, opts) do
    max = Keyword.get(opts, :max_resolved_resources, @default_max_resolved_resources)

    with :ok <- positive_limit(max, :max_resolved_resources) do
      case Keyword.get(opts, :limit_key) do
        nil ->
          :ok

        limit_key ->
          key = {__MODULE__, :resolved_resources, limit_key}
          seen = Process.get(key, MapSet.new())

          cond do
            MapSet.member?(seen, uri) ->
              :ok

            MapSet.size(seen) >= max ->
              {:error, :too_many_remote_schema_resources}

            true ->
              Process.put(key, MapSet.put(seen, uri))
              :ok
          end
      end
    end
  end

  defp wrap_boolean(uri, schema) when is_boolean(schema) do
    %{"$id" => uri, "allOf" => [schema]}
  end

  defp wrap_boolean(_uri, schema), do: schema

  defp positive_limit(value, _name) when is_integer(value) and value > 0, do: :ok
  defp positive_limit(_value, name), do: {:error, {:invalid_remote_schema_limit, name}}

  defp resolver_kind(value) do
    cond do
      is_function(value) -> :function
      is_atom(value) -> :module
      is_tuple(value) -> :tuple
      is_list(value) -> :list
      true -> :unsupported
    end
  end

  defp resolver_result_kind({tag, _value}) when is_atom(tag), do: tag
  defp resolver_result_kind(value) when is_map(value), do: :map
  defp resolver_result_kind(value) when is_list(value), do: :list
  defp resolver_result_kind(value) when is_atom(value), do: :atom
  defp resolver_result_kind(_value), do: :unsupported
end
