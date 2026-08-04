defmodule FastestMCP.Auth.ProtectedResource do
  @moduledoc """
  RFC 9728 Protected Resource Metadata for an HTTP MCP endpoint.

  FastestMCP remains a resource server: authorization-server discovery and
  token validation are application-owned. This value validates the metadata
  needed by standards-aware MCP clients and constructs the path-derived
  well-known URI and `WWW-Authenticate` challenge.
  """

  alias FastestMCP.Error

  @standard_fields MapSet.new([
                     "authorization_details_types_supported",
                     "authorization_servers",
                     "bearer_methods_supported",
                     "jwks_uri",
                     "resource",
                     "resource_documentation",
                     "resource_name",
                     "resource_policy_uri",
                     "resource_signing_alg_values_supported",
                     "resource_tos_uri",
                     "scopes_supported",
                     "signed_metadata",
                     "tls_client_certificate_bound_access_tokens"
                   ])

  @enforce_keys [:resource, :authorization_servers]
  defstruct [
    :resource,
    :authorization_servers,
    :scopes_supported,
    :required_scopes,
    :resource_name,
    :resource_documentation,
    :resource_policy_uri,
    :resource_tos_uri,
    :jwks_uri,
    :resource_signing_alg_values_supported,
    :tls_client_certificate_bound_access_tokens,
    :authorization_details_types_supported,
    :signed_metadata,
    bearer_methods_supported: ["header"],
    extensions: %{}
  ]

  @type t :: %__MODULE__{
          resource: String.t(),
          authorization_servers: [String.t()],
          scopes_supported: [String.t()] | nil,
          required_scopes: [String.t()],
          bearer_methods_supported: [String.t()],
          resource_name: String.t() | nil,
          resource_documentation: String.t() | nil,
          resource_policy_uri: String.t() | nil,
          resource_tos_uri: String.t() | nil,
          jwks_uri: String.t() | nil,
          resource_signing_alg_values_supported: [String.t()] | nil,
          tls_client_certificate_bound_access_tokens: boolean() | nil,
          authorization_details_types_supported: [String.t()] | nil,
          signed_metadata: String.t() | nil,
          extensions: map()
        }

  @doc "Builds validated Protected Resource Metadata."
  def new(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    with {:ok, resource} <- validate_resource_uri(fetch(opts, :resource)),
         {:ok, authorization_servers} <-
           validate_authorization_servers(fetch(opts, :authorization_servers)),
         {:ok, scopes_supported} <- validate_optional_scope_list(fetch(opts, :scopes_supported)),
         {:ok, required_scopes} <-
           validate_required_scopes(fetch(opts, :required_scopes, scopes_supported || [])),
         :ok <- validate_required_scopes_supported(required_scopes, scopes_supported),
         {:ok, bearer_methods_supported} <-
           validate_bearer_methods(fetch(opts, :bearer_methods_supported, ["header"])),
         {:ok, resource_name} <- validate_optional_string(fetch(opts, :resource_name)),
         {:ok, resource_documentation} <-
           validate_optional_https_uri(fetch(opts, :resource_documentation)),
         {:ok, resource_policy_uri} <-
           validate_optional_https_uri(fetch(opts, :resource_policy_uri)),
         {:ok, resource_tos_uri} <-
           validate_optional_https_uri(fetch(opts, :resource_tos_uri)),
         {:ok, jwks_uri} <- validate_optional_https_uri(fetch(opts, :jwks_uri)),
         {:ok, signing_algorithms} <-
           validate_optional_string_list(fetch(opts, :resource_signing_alg_values_supported)),
         {:ok, certificate_bound?} <-
           validate_optional_boolean(fetch(opts, :tls_client_certificate_bound_access_tokens)),
         {:ok, authorization_detail_types} <-
           validate_optional_string_list(fetch(opts, :authorization_details_types_supported)),
         {:ok, signed_metadata} <- validate_optional_string(fetch(opts, :signed_metadata)),
         {:ok, extensions} <- validate_extensions(fetch(opts, :extensions, %{})) do
      {:ok,
       %__MODULE__{
         resource: resource,
         authorization_servers: authorization_servers,
         scopes_supported: scopes_supported,
         required_scopes: required_scopes,
         bearer_methods_supported: bearer_methods_supported,
         resource_name: resource_name,
         resource_documentation: resource_documentation,
         resource_policy_uri: resource_policy_uri,
         resource_tos_uri: resource_tos_uri,
         jwks_uri: jwks_uri,
         resource_signing_alg_values_supported: signing_algorithms,
         tls_client_certificate_bound_access_tokens: certificate_bound?,
         authorization_details_types_supported: authorization_detail_types,
         signed_metadata: signed_metadata,
         extensions: extensions
       }}
    end
  end

  @doc "Builds metadata, raising `ArgumentError` on invalid configuration."
  def new!(opts) do
    case new(opts) do
      {:ok, protected_resource} ->
        protected_resource

      {:error, reason} ->
        raise ArgumentError, "invalid protected resource: #{format_reason(reason)}"
    end
  end

  @doc "Returns the RFC 9728 JSON document with string keys."
  def metadata(%__MODULE__{} = protected_resource) do
    protected_resource.extensions
    |> Map.put("resource", protected_resource.resource)
    |> Map.put("authorization_servers", protected_resource.authorization_servers)
    |> Map.put("bearer_methods_supported", protected_resource.bearer_methods_supported)
    |> maybe_put("scopes_supported", protected_resource.scopes_supported)
    |> maybe_put("resource_name", protected_resource.resource_name)
    |> maybe_put("resource_documentation", protected_resource.resource_documentation)
    |> maybe_put("resource_policy_uri", protected_resource.resource_policy_uri)
    |> maybe_put("resource_tos_uri", protected_resource.resource_tos_uri)
    |> maybe_put("jwks_uri", protected_resource.jwks_uri)
    |> maybe_put(
      "resource_signing_alg_values_supported",
      protected_resource.resource_signing_alg_values_supported
    )
    |> maybe_put(
      "tls_client_certificate_bound_access_tokens",
      protected_resource.tls_client_certificate_bound_access_tokens
    )
    |> maybe_put(
      "authorization_details_types_supported",
      protected_resource.authorization_details_types_supported
    )
    |> maybe_put("signed_metadata", protected_resource.signed_metadata)
  end

  @doc "Returns the RFC 9728 path-derived well-known path."
  def metadata_path(%__MODULE__{resource: resource}) do
    case URI.parse(resource).path do
      path when path in [nil, "", "/"] -> "/.well-known/oauth-protected-resource"
      path -> "/.well-known/oauth-protected-resource" <> ensure_leading_slash(path)
    end
  end

  @doc "Returns the absolute URL of the Protected Resource Metadata document."
  def metadata_url(%__MODULE__{resource: resource} = protected_resource) do
    resource
    |> URI.parse()
    |> Map.put(:path, metadata_path(protected_resource))
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  @doc "Returns whether a request path is this resource's well-known metadata path."
  def matches_path?(%__MODULE__{} = protected_resource, request_path)
      when is_binary(request_path) do
    request_path == metadata_path(protected_resource)
  end

  @doc "Returns whether an absolute URI is exactly this protected resource."
  def matches_resource?(%__MODULE__{resource: resource}, candidate) when is_binary(candidate) do
    case validate_resource_uri(candidate) do
      {:ok, canonical_candidate} -> canonical_candidate == resource
      {:error, _reason} -> false
    end
  end

  def matches_resource?(%__MODULE__{}, _candidate), do: false

  @doc "Builds an RFC 9728/RFC 6750 Bearer challenge."
  def www_authenticate(%__MODULE__{} = protected_resource, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, protected_resource.required_scopes)

    [~s(resource_metadata="#{escape(metadata_url(protected_resource))}")]
    |> maybe_append_scope(scopes)
    |> maybe_append_error(Keyword.get(opts, :error))
    |> maybe_append_parameter("error_description", Keyword.get(opts, :error_description))
    |> then(&("Bearer " <> Enum.join(&1, ", ")))
  end

  defp validate_resource_uri(value) do
    with {:ok, uri} <- parse_absolute_http_uri(value),
         :ok <- validate_resource_scheme(uri) do
      {:ok, canonical_uri(uri)}
    end
  end

  defp validate_resource_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_resource_scheme(%URI{scheme: "http", host: host}) do
    if loopback_host?(host), do: :ok, else: {:error, :https_resource_required}
  end

  defp validate_resource_scheme(_uri), do: {:error, :invalid_resource_uri}

  defp validate_authorization_servers(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, servers} ->
      case parse_absolute_https_uri(value) do
        {:ok, uri} -> {:cont, {:ok, [canonical_uri(uri) | servers]}}
        {:error, _reason} -> {:halt, {:error, :invalid_authorization_server}}
      end
    end)
    |> case do
      {:ok, servers} -> {:ok, servers |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp validate_authorization_servers(_values), do: {:error, :authorization_servers_required}

  defp validate_bearer_methods(["header"]), do: {:ok, ["header"]}
  defp validate_bearer_methods(_methods), do: {:error, :header_bearer_method_required}

  defp validate_optional_string(nil), do: {:ok, nil}
  defp validate_optional_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp validate_optional_string(_value), do: {:error, :invalid_string_metadata}

  defp validate_optional_string_list(nil), do: {:ok, nil}

  defp validate_optional_string_list(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(values)}
    else
      {:error, :invalid_string_list_metadata}
    end
  end

  defp validate_optional_string_list(_values), do: {:error, :invalid_string_list_metadata}

  defp validate_optional_scope_list(nil), do: {:ok, nil}

  defp validate_optional_scope_list(values) when is_list(values) do
    if Enum.all?(values, &valid_scope_token?/1) do
      {:ok, Enum.uniq(values)}
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_optional_scope_list(_values), do: {:error, :invalid_scope}

  defp validate_required_scopes(values) when is_list(values) do
    if Enum.all?(values, &valid_scope_token?/1) do
      {:ok, Enum.uniq(values)}
    else
      {:error, :invalid_required_scope}
    end
  end

  defp validate_required_scopes(_values), do: {:error, :invalid_required_scope}

  defp validate_required_scopes_supported(_required_scopes, nil), do: :ok

  defp validate_required_scopes_supported(required_scopes, scopes_supported) do
    case required_scopes -- scopes_supported do
      [] -> :ok
      unsupported -> {:error, {:unsupported_required_scopes, unsupported}}
    end
  end

  defp validate_optional_boolean(nil), do: {:ok, nil}
  defp validate_optional_boolean(value) when is_boolean(value), do: {:ok, value}
  defp validate_optional_boolean(_value), do: {:error, :invalid_boolean_metadata}

  defp validate_optional_https_uri(nil), do: {:ok, nil}

  defp validate_optional_https_uri(value) do
    case parse_absolute_https_uri(value) do
      {:ok, uri} -> {:ok, canonical_uri(uri)}
      {:error, _reason} -> {:error, :invalid_https_metadata_uri}
    end
  end

  defp validate_extensions(extensions) when is_map(extensions) do
    Enum.reduce_while(extensions, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_binary(key) and key != "" ->
        cond do
          MapSet.member?(@standard_fields, key) ->
            {:halt, {:error, {:reserved_extension, key}}}

          not json_value?(value) ->
            {:halt, {:error, {:invalid_extension_value, key}}}

          true ->
            {:cont, {:ok, Map.put(normalized, key, value)}}
        end

      {_key, _value}, _acc ->
        {:halt, {:error, :invalid_extension}}
    end)
  end

  defp validate_extensions(_extensions), do: {:error, :invalid_extension}

  defp parse_absolute_http_uri(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} -> validate_absolute_http_uri(uri)
      {:error, _reason} -> {:error, :invalid_absolute_uri}
    end
  end

  defp parse_absolute_http_uri(_value), do: {:error, :invalid_absolute_uri}

  defp validate_absolute_http_uri(uri) do
    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_absolute_uri}
      not is_binary(uri.host) or uri.host == "" -> {:error, :invalid_absolute_uri}
      not is_nil(uri.userinfo) -> {:error, :invalid_absolute_uri}
      not is_nil(uri.query) or not is_nil(uri.fragment) -> {:error, :invalid_absolute_uri}
      not valid_percent_encoding?(uri.path) -> {:error, :invalid_absolute_uri}
      true -> {:ok, uri}
    end
  end

  defp parse_absolute_https_uri(value) do
    with {:ok, %URI{scheme: "https"} = uri} <- parse_absolute_http_uri(value) do
      {:ok, uri}
    else
      _other -> {:error, :https_required}
    end
  end

  defp canonical_uri(uri) do
    uri
    |> Map.update!(:scheme, &String.downcase/1)
    |> Map.update!(:host, &String.downcase/1)
    |> normalize_default_port()
    |> URI.to_string()
  end

  defp normalize_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp normalize_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp normalize_default_port(uri), do: uri

  defp loopback_host?(host) when is_binary(host) do
    String.downcase(host) in ["localhost", "127.0.0.1", "::1"]
  end

  defp loopback_host?(_host), do: false

  defp maybe_append_scope(parameters, nil), do: parameters
  defp maybe_append_scope(parameters, []), do: parameters

  defp maybe_append_scope(parameters, scopes) when is_list(scopes) do
    if Enum.all?(scopes, &valid_scope_token?/1) do
      parameters ++ [~s(scope="#{Enum.join(scopes, " ")}")]
    else
      raise ArgumentError, "challenge scopes must be non-empty RFC 6749 scope tokens"
    end
  end

  defp maybe_append_scope(parameters, scope) when is_binary(scope) and scope != "" do
    tokens = String.split(scope, " ", trim: true)

    if tokens != [] and Enum.all?(tokens, &valid_scope_token?/1) and
         not String.contains?(scope, ["\r", "\n", "\t"]) do
      parameters ++ [~s(scope="#{Enum.join(tokens, " ")}")]
    else
      raise ArgumentError, "challenge scope must contain RFC 6749 scope tokens"
    end
  end

  defp maybe_append_scope(parameters, _scope), do: parameters

  defp maybe_append_error(parameters, nil), do: parameters

  defp maybe_append_error(parameters, %Error{code: :forbidden}),
    do: parameters ++ [~s(error="insufficient_scope")]

  defp maybe_append_error(parameters, %Error{}),
    do: parameters ++ [~s(error="invalid_token")]

  defp maybe_append_error(parameters, error) when is_binary(error) and error != "",
    do: parameters ++ [~s(error="#{escape(error)}")]

  defp maybe_append_error(parameters, _error), do: parameters

  defp maybe_append_parameter(parameters, _name, nil), do: parameters

  defp maybe_append_parameter(parameters, name, value) when is_binary(value) and value != "",
    do: parameters ++ [~s(#{name}="#{escape(value)}")]

  defp maybe_append_parameter(parameters, _name, _value), do: parameters

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace(["\r", "\n"], " ")
  end

  defp ensure_leading_slash("/" <> _rest = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  defp valid_scope_token?(value) when is_binary(value) and value != "" do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn character ->
      character == 0x21 or character in 0x23..0x5B or character in 0x5D..0x7E
    end)
  end

  defp valid_scope_token?(_value), do: false

  defp json_value?(value) do
    _encoded = JSON.encode!(value)
    true
  rescue
    _error -> false
  end

  defp valid_percent_encoding?(nil), do: true

  defp valid_percent_encoding?(value) do
    not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value)
  end

  defp fetch(opts, key, default \\ nil) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp format_reason({:reserved_extension, key}), do: "extension #{inspect(key)} is reserved"
  defp format_reason(reason), do: inspect(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
