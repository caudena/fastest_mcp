defmodule FastestMCP.Options do
  @moduledoc false
  # Keyword option validation. A spec maps each allowed key to `{rule, default}`;
  # unknown or duplicate keys and invalid values raise `ArgumentError`
  # (`keys!/2` checks keys alone). Defaults are not checked, so a nil default
  # makes an option optional. Key errors never print the options themselves:
  # their values may be credentials.

  # Returns a map with every spec key.
  def validate!(opts, spec) do
    opts = keys!(opts, Keyword.keys(spec))

    Map.new(spec, fn {key, {rule, default}} ->
      value = Keyword.get(opts, key, default)
      {key, if(value === default, do: value, else: check!(value, rule, key))}
    end)
  end

  def keys!(opts, allowed) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")
    keys = Keyword.keys(opts)

    case {Enum.reject(keys, &(&1 in allowed)), keys -- Enum.uniq(keys)} do
      {[], []} ->
        opts

      {[], duplicate} ->
        raise ArgumentError, "duplicate keys #{inspect(Enum.uniq(duplicate))}"

      {unknown, _duplicate} ->
        raise ArgumentError,
              "unknown keys #{inspect(unknown)}, the allowed keys are: #{inspect(allowed)}"
    end
  end

  def check!(value, :module_with_opts, _key) when is_atom(value) and value != nil,
    do: {value, []}

  def check!({module, opts} = value, :module_with_opts, _key)
      when is_atom(module) and is_list(opts),
      do: value

  def check!(value, rule, key) do
    if valid?(value, rule) do
      value
    else
      raise ArgumentError, "#{key} must be #{describe(rule)}, got: #{inspect(value)}"
    end
  end

  defp valid?(value, :pos_integer), do: is_integer(value) and value > 0
  defp valid?(value, :non_neg_integer), do: is_integer(value) and value >= 0
  defp valid?(value, :limit), do: value == :infinity or valid?(value, :pos_integer)
  defp valid?(value, :non_neg_limit), do: value == :infinity or valid?(value, :non_neg_integer)
  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(value, :keyword), do: Keyword.keyword?(value)
  defp valid?(value, :function), do: is_function(value)
  defp valid?(_value, :module_with_opts), do: false
  defp valid?(_value, :any), do: true

  defp describe(:pos_integer), do: "a positive integer"
  defp describe(:non_neg_integer), do: "a non-negative integer"
  defp describe(:limit), do: "a positive integer or :infinity"
  defp describe(:non_neg_limit), do: "a non-negative integer or :infinity"
  defp describe(:boolean), do: "a boolean"
  defp describe(:keyword), do: "a keyword list"
  defp describe(:function), do: "a function"
  defp describe(:module_with_opts), do: "a module or {module, opts}"
end
