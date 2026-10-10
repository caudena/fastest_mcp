defmodule FastestMCP.ProviderTransforms.Namespace do
  @moduledoc """
  A provider transform that prefixes a provider's identifiers with a
  namespace, so mounted or dynamic components cannot collide with the parent
  server's. Tools and prompts become `namespace_name`; resource and template
  URIs become `scheme://namespace/rest`. Calls to the namespaced identifiers
  reach the source components.

  `FastestMCP.mount/3` applies one for its `namespace:` option.
  """

  use FastestMCP.ProviderTransform

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler

  defstruct [:namespace]

  @doc """
  Builds the transform; a blank `namespace` leaves identifiers unchanged.

  A namespace takes the characters of a tool name (letters, digits, `_`, `-`,
  and `.`), so namespaced names stay valid; any other raises `ArgumentError`.
  """
  def new(namespace) do
    %__MODULE__{namespace: normalize_namespace(namespace)}
  end

  @impl FastestMCP.ProviderTransform
  def transform_component(%__MODULE__{namespace: namespace}, component, _operation) do
    identifier = namespaced(namespace, Component.kind(component), Component.identifier(component))
    Component.put_identifier(component, identifier)
  end

  @impl FastestMCP.ProviderTransform
  def reverse_identifier(%__MODULE__{namespace: namespace}, kind, identifier, _operation)
      when kind in [:tool, :prompt],
      do: strip_name_prefix(namespace, identifier)

  def reverse_identifier(%__MODULE__{namespace: namespace}, kind, identifier, _operation)
      when kind in [:resource, :resource_template],
      do: strip_uri_namespace(namespace, identifier)

  def reverse_identifier(%__MODULE__{}, _kind, identifier, _operation),
    do: {:ok, to_string(identifier)}

  defp normalize_namespace(nil), do: nil

  defp normalize_namespace(namespace) do
    case namespace |> to_string() |> String.trim() do
      "" ->
        nil

      value ->
        if ComponentCompiler.name_characters?(value) do
          value
        else
          raise ArgumentError,
                ~s(namespace must be letters, digits, "_", "-", or ".", got: #{inspect(value)})
        end
    end
  end

  defp namespaced(nil, _kind, identifier), do: to_string(identifier)

  defp namespaced(namespace, kind, name) when kind in [:tool, :prompt],
    do: namespace <> "_" <> to_string(name)

  defp namespaced(namespace, _kind, uri) do
    uri = to_string(uri)

    case String.split(uri, "://", parts: 2) do
      [scheme, rest] -> scheme <> "://" <> namespace <> "/" <> rest
      _ -> namespace <> "/" <> uri
    end
  end

  defp strip_name_prefix(nil, identifier), do: {:ok, to_string(identifier)}

  defp strip_name_prefix(namespace, identifier) do
    prefix = namespace <> "_"
    identifier = to_string(identifier)

    if String.starts_with?(identifier, prefix) do
      {:ok, binary_part(identifier, byte_size(prefix), byte_size(identifier) - byte_size(prefix))}
    else
      :error
    end
  end

  defp strip_uri_namespace(nil, identifier), do: {:ok, to_string(identifier)}

  defp strip_uri_namespace(namespace, identifier) do
    identifier = to_string(identifier)

    case String.split(identifier, "://", parts: 2) do
      [scheme, rest] ->
        prefix = namespace <> "/"

        if String.starts_with?(rest, prefix) do
          stripped = binary_part(rest, byte_size(prefix), byte_size(rest) - byte_size(prefix))
          {:ok, scheme <> "://" <> stripped}
        else
          :error
        end

      _ ->
        :error
    end
  end
end
