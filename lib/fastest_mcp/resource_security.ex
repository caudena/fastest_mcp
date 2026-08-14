defmodule FastestMCP.ResourceSecurity do
  @moduledoc """
  Lexical screening policy for decoded resource-template parameters.

  This policy rejects values that would commonly escape a logical resource
  root. It deliberately does not inspect a filesystem, resolve symlinks, or
  recursively decode percent-encoded input.
  """

  @enforce_keys []
  defstruct reject_path_traversal: true,
            reject_absolute_paths: true,
            reject_null_bytes: true,
            exempt_params: MapSet.new()

  @type t :: %__MODULE__{
          reject_path_traversal: boolean(),
          reject_absolute_paths: boolean(),
          reject_null_bytes: boolean(),
          exempt_params: MapSet.t(String.t())
        }

  @fields [
    :reject_path_traversal,
    :reject_absolute_paths,
    :reject_null_bytes,
    :exempt_params
  ]

  @doc "Builds and validates a resource-security policy."
  def new(options \\ [])

  def new(%__MODULE__{} = policy), do: normalize_policy(policy)

  def new(options) when is_list(options) do
    if Keyword.keyword?(options), do: new(Map.new(options)), else: invalid_policy!(options)
  end

  def new(options) when is_map(options) do
    normalized =
      Map.new(options, fn {key, value} ->
        normalized_key = normalize_field(key)
        {normalized_key, value}
      end)

    unknown = Map.keys(normalized) -- @fields

    if unknown != [] do
      raise ArgumentError, "unknown resource_security options: #{inspect(unknown)}"
    end

    struct(__MODULE__, normalized)
    |> normalize_policy()
  end

  def new(other), do: invalid_policy!(other)

  @doc false
  def screen(captures, nil) when is_map(captures), do: :ok

  def screen(captures, %__MODULE__{} = policy) when is_map(captures) do
    captures
    |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
    |> Enum.reduce_while(:ok, fn {name, value}, :ok ->
      parameter = to_string(name)

      if exempt?(policy, parameter) do
        {:cont, :ok}
      else
        case screen_value(value, policy) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason, parameter}}
        end
      end
    end)
  end

  defp screen_value(value, policy) when is_binary(value), do: screen_binary(value, policy)

  defp screen_value(values, policy) when is_list(values) do
    Enum.reduce_while(values, :ok, fn
      value, :ok when is_binary(value) ->
        case screen_binary(value, policy) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, :ok ->
        {:cont, :ok}
    end)
  end

  defp screen_value(_value, _policy), do: :ok

  defp screen_binary(value, policy) do
    cond do
      policy.reject_null_bytes and :binary.match(value, <<0>>) != :nomatch ->
        {:error, :null_byte}

      policy.reject_path_traversal and escapes_base?(value) ->
        {:error, :path_traversal}

      policy.reject_absolute_paths and absolute_path?(value) ->
        {:error, :absolute_path}

      true ->
        :ok
    end
  end

  defp escapes_base?(value) do
    value
    |> String.replace("\\", "/")
    |> String.split("/", trim: false)
    |> Enum.reduce_while(0, fn
      segment, depth when segment in ["", "."] -> {:cont, depth}
      "..", 0 -> {:halt, :escaped}
      "..", depth -> {:cont, depth - 1}
      _segment, depth -> {:cont, depth + 1}
    end)
    |> Kernel.==(:escaped)
  end

  defp absolute_path?(<<first, _rest::binary>>) when first in [?/, ?\\], do: true

  defp absolute_path?(<<letter, ?:, _rest::binary>>)
       when letter in ?A..?Z or letter in ?a..?z,
       do: true

  defp absolute_path?(_value), do: false

  defp exempt?(%__MODULE__{exempt_params: exemptions}, parameter) do
    MapSet.member?(exemptions, parameter) or
      MapSet.member?(exemptions, normalize_parameter_name(parameter))
  end

  defp normalize_policy(%__MODULE__{} = policy) do
    Enum.each(
      [
        reject_path_traversal: policy.reject_path_traversal,
        reject_absolute_paths: policy.reject_absolute_paths,
        reject_null_bytes: policy.reject_null_bytes
      ],
      fn {field, value} ->
        unless is_boolean(value) do
          raise ArgumentError, "resource_security #{field} must be a boolean"
        end
      end
    )

    exemptions =
      policy.exempt_params
      |> normalize_exemptions()
      |> Enum.flat_map(fn name -> [name, normalize_parameter_name(name)] end)
      |> MapSet.new()

    %{policy | exempt_params: exemptions}
  end

  defp normalize_exemptions(%MapSet{} = exemptions), do: MapSet.to_list(exemptions)
  defp normalize_exemptions(nil), do: []

  defp normalize_exemptions(exemptions) when is_list(exemptions) do
    Enum.map(exemptions, &normalize_exemption!/1)
  end

  defp normalize_exemptions(other) do
    raise ArgumentError,
          "resource_security exempt_params must be a list or MapSet, got: #{inspect(other)}"
  end

  defp normalize_exemption!(value) when is_atom(value) or is_binary(value), do: to_string(value)

  defp normalize_exemption!(value) do
    raise ArgumentError,
          "resource_security exemption names must be atoms or strings, got: #{inspect(value)}"
  end

  defp normalize_parameter_name(name), do: String.replace(name, "_", "-")

  defp normalize_field(field) when is_atom(field), do: field

  defp normalize_field(field) when is_binary(field) do
    case Enum.find(@fields, &(Atom.to_string(&1) == field)) do
      nil -> field
      known -> known
    end
  end

  defp normalize_field(field), do: field

  defp invalid_policy!(value) do
    raise ArgumentError,
          "resource_security must be a keyword list, map, or FastestMCP.ResourceSecurity, got: #{inspect(value)}"
  end
end
