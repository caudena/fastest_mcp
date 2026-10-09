defmodule FastestMCP.Schema do
  @moduledoc """
  Compile-once JSON Schema validation for FastestMCP.

  Schemas default to JSON Schema Draft 2020-12. Draft 7 is also accepted when
  selected explicitly. Validation never coerces submitted values and remote
  references fail closed unless an application resolver is provided.
  """

  alias FastestMCP.Schema.Compiled
  alias FastestMCP.Schema.Error
  alias FastestMCP.Schema.HTTPResolver
  alias FastestMCP.Schema.Policy
  alias FastestMCP.Schema.Resolver
  alias FastestMCP.Util

  @draft_2020_12 "https://json-schema.org/draft/2020-12/schema"
  @draft_7 "http://json-schema.org/draft-07/schema"
  @supported_dialects Policy.dialects()
  @default_max_schema_bytes Policy.default(:max_schema_bytes)
  @default_max_depth Policy.default(:max_depth)
  @default_max_refs Policy.default(:max_refs)
  @default_max_resolved_resources Policy.default(:max_resolved_resources)
  @default_max_violations 20
  @default_compile_timeout_ms 5_000
  @default_validation_timeout_ms 1_000

  # Violation messages name the failed keyword and never echo the value.
  @violation_messages %{
    "type" => "value has an invalid JSON type",
    "enum" => "value is not one of the allowed values",
    "const" => "value does not match the required constant",
    "required" => "a required property is missing",
    "additionalProperties" => "additional properties are not allowed",
    "unevaluatedProperties" => "unevaluated properties are not allowed",
    "propertyNames" => "an object property name is invalid",
    "uniqueItems" => "array items must be unique",
    "minimum" => "number is below the allowed minimum",
    "maximum" => "number is above the allowed maximum",
    "exclusiveMinimum" => "number is not above the exclusive minimum",
    "exclusiveMaximum" => "number is not below the exclusive maximum",
    "multipleOf" => "number is not an allowed multiple",
    "minLength" => "string is shorter than allowed",
    "maxLength" => "string is longer than allowed",
    "pattern" => "string does not match the required pattern",
    "format" => "string has an invalid format",
    "minItems" => "array has too few items",
    "maxItems" => "array has too many items",
    "contains" => "array does not contain the required items",
    "minContains" => "array contains too few matching items",
    "maxContains" => "array contains too many matching items",
    "minProperties" => "object has too few properties",
    "maxProperties" => "object has too many properties",
    "dependentRequired" => "a dependent property is missing",
    "not" => "value matches a forbidden schema",
    "oneOf" => "value does not match exactly one allowed schema",
    "anyOf" => "value does not match any allowed schema",
    "allOf" => "value does not match every required schema",
    "if" => "value does not satisfy the conditional schema"
  }

  @type raw :: boolean() | map()

  @doc """
  Compiles a JSON Schema into a reusable validator.

  Options include the limits `:max_schema_bytes`, `:max_depth`, `:max_refs`,
  and `:max_resolved_resources`, `:compile_timeout_ms` (default 5,000), and
  `:validation_timeout_ms` (default 1,000), which bounds every validation with
  the compiled validator.
  """
  @spec compile(raw(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compile(schema, opts \\ []) when is_list(opts) do
    timeout_ms = timeout_option!(opts, :compile_timeout_ms, @default_compile_timeout_ms)

    validation_timeout_ms =
      timeout_option!(opts, :validation_timeout_ms, @default_validation_timeout_ms)

    with {:ok, compiled} <- run_bounded(fn -> do_compile(schema, opts) end, timeout_ms, :compile),
         do: {:ok, %{compiled | validation_timeout_ms: validation_timeout_ms}}
  end

  defp do_compile(schema, opts) do
    with {:ok, normalized} <- normalize(schema),
         {:ok, dialect} <- dialect(normalized),
         :ok <- preflight(normalized, opts),
         :ok <- validate_schema_definition(normalized, dialect),
         digest <- digest_normalized(normalized),
         {:ok, root} <- build(normalized, dialect, opts, digest) do
      {:ok,
       %Compiled{
         root: root,
         source: normalized,
         digest: digest,
         dialect: dialect
       }}
    end
  end

  @doc "Compiles a JSON Schema, raising `FastestMCP.Schema.Error` on failure."
  @spec compile!(raw(), keyword()) :: Compiled.t()
  def compile!(schema, opts \\ []) do
    case compile(schema, opts) do
      {:ok, compiled} -> compiled
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Validates a value without coercion and returns the original value on success,
  within the validator's `:validation_timeout_ms`.
  """
  @spec validate(Compiled.t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate(%Compiled{} = compiled, value) do
    run_bounded(
      fn -> validate_inline(compiled, value) end,
      compiled.validation_timeout_ms,
      :validation
    )
  end

  @doc false
  @spec validate_source(Compiled.t() | raw(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate_source(source, value) when is_map(source) or is_boolean(source) do
    case Compiled.cast(source) do
      {:ok, compiled} ->
        validate(compiled, value)

      :error ->
        with {:ok, compiled} <- compile(source) do
          validate(compiled, value)
        end
    end
  end

  # Validates in the calling process. Only for trusted schemas, such as the
  # vendored MCP protocol schemas, whose validation time is bounded by the input.
  @doc false
  def validate_inline(%Compiled{} = compiled, value) do
    case JSV.validate(value, Compiled.root(compiled), cast: false, cast_formats: false) do
      {:ok, _jsv_value} ->
        {:ok, value}

      {:error, validation_error} ->
        violations = normalize_violations(validation_error, @default_max_violations)

        {:error,
         %Error{
           phase: :validation,
           digest: compiled.digest,
           violations: violations,
           message: validation_message(violations)
         }}
    end
  end

  @doc "Returns a deterministic SHA-256 digest for a JSON Schema."
  @spec digest(raw()) :: {:ok, String.t()} | {:error, Error.t()}
  def digest(schema) do
    case normalize(schema) do
      {:ok, normalized} -> {:ok, digest_normalized(normalized)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Returns whether the schema has the MCP-required object root."
  @spec object_root?(term()) :: boolean()
  def object_root?(schema) do
    case normalize(schema) do
      {:ok, %{"type" => "object"}} -> true
      _other -> false
    end
  end

  @doc false
  @spec validate_schema_definition(raw(), String.t()) :: :ok | {:error, Error.t()}
  def validate_schema_definition(schema, dialect) when dialect in @supported_dialects do
    case JSV.validate(schema, meta_schema_root(dialect), cast: false, cast_formats: false) do
      {:ok, _schema} ->
        :ok

      {:error, validation_error} ->
        violations = normalize_violations(validation_error, @default_max_violations)

        {:error,
         %Error{
           phase: :compile,
           digest: digest_normalized(schema),
           violations: violations,
           message: "invalid JSON Schema: " <> validation_message(violations)
         }}
    end
  end

  def validate_schema_definition(_schema, _dialect) do
    {:error, compile_error("unsupported JSON Schema dialect")}
  end

  defp meta_schema_root(dialect) do
    Util.cached({__MODULE__, :meta_schema, dialect}, fn ->
      dialect
      |> meta_schema_source()
      |> JSV.build!(
        atoms: false,
        default_meta: dialect,
        formats: JSV.default_format_validator_modules(),
        warnings: :silent
      )
    end)
  end

  defp meta_schema_source(@draft_2020_12),
    do: JSV.Resolver.Embedded.Draft202012.Schema.json_schema()

  defp meta_schema_source(@draft_7),
    do: JSV.Resolver.Embedded.Draft7.Schema.json_schema()

  @doc false
  @spec normalize(raw()) :: {:ok, raw()} | {:error, Error.t()}
  def normalize(schema) when is_boolean(schema) or is_map(schema) do
    {:ok, JSV.Schema.normalize(schema)}
  rescue
    _error -> {:error, compile_error("invalid JSON Schema")}
  end

  def normalize(_schema), do: {:error, compile_error("JSON Schema must be an object or boolean")}

  defp dialect(true), do: {:ok, @draft_2020_12}
  defp dialect(false), do: {:ok, @draft_2020_12}

  defp dialect(schema) do
    case Map.get(schema, "$schema") do
      nil -> {:ok, @draft_2020_12}
      value when is_binary(value) -> normalize_dialect(value)
      _other -> {:error, compile_error("JSON Schema $schema must be a string")}
    end
  end

  defp normalize_dialect(value) do
    case Policy.normalize_dialect(value) do
      {:ok, dialect} ->
        {:ok, dialect}

      {:error, _} ->
        {:error,
         compile_error(
           "unsupported JSON Schema dialect; supported dialects are Draft 2020-12 and Draft 7"
         )}
    end
  end

  defp preflight(schema, opts) do
    case Policy.check(schema, opts) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, compile_error(Policy.message(reason))}
    end
  end

  defp build(schema, dialect, opts, digest) do
    remote_limits = [
      limit_key: make_ref(),
      max_schema_bytes: Keyword.get(opts, :max_schema_bytes, @default_max_schema_bytes),
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      max_refs: Keyword.get(opts, :max_refs, @default_max_refs),
      max_resolved_resources:
        Keyword.get(opts, :max_resolved_resources, @default_max_resolved_resources),
      default_dialect: dialect
    ]

    build_opts = [
      atoms: false,
      default_meta: dialect,
      formats: nil,
      resolver: resolvers(opts, remote_limits),
      warnings: :silent
    ]

    {:ok, JSV.build!(schema, build_opts)}
  rescue
    _error ->
      {:error, %Error{phase: :compile, digest: digest, message: "could not compile JSON Schema"}}
  end

  defp resolvers(opts, remote_limits) do
    []
    |> add_application_resolver(Keyword.get(opts, :resolver), remote_limits)
    |> add_http_resolver(Keyword.get(opts, :http_resolver), remote_limits)
  end

  defp add_application_resolver(resolvers, nil, _remote_limits), do: resolvers

  defp add_application_resolver(resolvers, resolver, remote_limits) do
    entries =
      case resolver do
        resolver when is_list(resolver) -> resolver
        resolver -> [resolver]
      end

    wrapped =
      Enum.map(entries, fn entry ->
        {Resolver, Keyword.put(remote_limits, :resolver, entry)}
      end)

    resolvers ++ wrapped
  end

  defp add_http_resolver(resolvers, nil, _remote_limits), do: resolvers

  defp add_http_resolver(resolvers, opts, remote_limits) when is_list(opts),
    do: resolvers ++ [{HTTPResolver, Keyword.merge(opts, remote_limits)}]

  defp add_http_resolver(resolvers, opts, remote_limits),
    do: resolvers ++ [{HTTPResolver, Keyword.put(remote_limits, :invalid_options, opts)}]

  defp normalize_violations(validation_error, limit) do
    validation_error
    |> JSV.normalize_error(keys: :strings, sort: :asc)
    |> Map.get("details", [])
    |> Enum.flat_map(&violation_entries/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn violation ->
      {-path_depth(violation.instance_path), violation.instance_path, violation.keyword}
    end)
    |> Enum.take(limit)
  end

  defp violation_entries(unit) do
    errors = Map.get(unit, "errors", [])

    Enum.flat_map(errors, fn error ->
      case Map.get(error, "details") do
        details when is_list(details) and details != [] ->
          case Enum.flat_map(details, &violation_entries/1) do
            [] -> [violation(unit, error)]
            nested -> nested
          end

        _other ->
          [violation(unit, error)]
      end
    end)
  end

  defp violation(unit, error) do
    schema_path = Map.get(unit, "schemaLocation", "#")
    {keyword, message} = normalize_keyword_error(error, schema_path)

    instance_path =
      unit
      |> Map.get("instanceLocation", "#")
      |> sanitize_instance_path(keyword)

    %{
      instance_path: bounded_binary(instance_path, 300),
      schema_path: bounded_binary(schema_path, 300),
      keyword: bounded_binary(keyword, 100),
      message: bounded_binary(message, 300)
    }
  end

  # The final path segment for these failures comes from an unrecognized input
  # property rather than from the schema. Omitting it keeps violations useful
  # without reflecting attacker-controlled or sensitive field names.
  defp sanitize_instance_path(path, keyword)
       when keyword in ["additionalProperties", "unevaluatedProperties"] do
    case String.split(to_string(path), "/") do
      ["#"] -> "#"
      segments -> segments |> Enum.drop(-1) |> Enum.join("/") |> non_empty_path()
    end
  end

  defp sanitize_instance_path(path, _keyword), do: to_string(path)

  defp non_empty_path(""), do: "#"
  defp non_empty_path(path), do: path

  defp normalize_keyword_error(%{"kind" => "boolean_schema"}, schema_path) do
    cond do
      String.ends_with?(schema_path, "/additionalProperties") ->
        {"additionalProperties", "additional properties are not allowed"}

      String.ends_with?(schema_path, "/unevaluatedProperties") ->
        {"unevaluatedProperties", "unevaluated properties are not allowed"}

      true ->
        {"boolean_schema", "value does not match schema"}
    end
  end

  defp normalize_keyword_error(error, _schema_path) do
    keyword = to_string(Map.get(error, "kind", "unknown"))
    {keyword, Map.get(@violation_messages, keyword, "value does not match schema")}
  end

  defp validation_message([]), do: "value does not match JSON Schema"

  defp validation_message([violation | _rest]) do
    bounded_binary("#{violation.instance_path} #{violation.message}", 500)
  end

  defp path_depth("#"), do: 0
  defp path_depth(path), do: path |> String.split("/", trim: true) |> length()

  defp digest_normalized(schema) do
    schema
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp compile_error(message) do
    %Error{phase: :compile, message: bounded_binary(message, 500), violations: []}
  end

  # User schemas and resolvers are untrusted: compile and validate them in a
  # task that is killed at the deadline. Before the application starts, as
  # when a stdio script defines its server, the task is linked to the caller.
  defp run_bounded(fun, timeout_ms, phase) do
    task =
      case Process.whereis(FastestMCP.TaskSupervisor) do
        nil -> Task.async(fun)
        supervisor -> Task.Supervisor.async_nolink(supervisor, fun)
      end

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        bounded_error(phase, "exceeded #{timeout_ms}ms", "timeout", "operation timed out")

      {:exit, _reason} ->
        bounded_error(phase, "failed", "runtime", "validator process failed")
    end
  end

  defp bounded_error(phase, outcome, keyword, message) do
    {:error,
     %Error{
       phase: phase,
       message: "JSON Schema #{phase} #{outcome}",
       violations: [%{instance_path: "#", schema_path: "#", keyword: keyword, message: message}]
     }}
  end

  defp timeout_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp bounded_binary(value, max_bytes) do
    value = to_string(value)

    if byte_size(value) <= max_bytes do
      value
    else
      prefix_bytes = max(max_bytes - byte_size("…"), 0)

      value
      |> binary_part(0, prefix_bytes)
      |> valid_utf8_prefix()
      |> Kernel.<>("…")
    end
  end

  defp valid_utf8_prefix(value) do
    cond do
      String.valid?(value) -> value
      byte_size(value) == 0 -> ""
      true -> value |> binary_part(0, byte_size(value) - 1) |> valid_utf8_prefix()
    end
  end
end
