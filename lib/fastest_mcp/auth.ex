defmodule FastestMCP.Auth do
  @moduledoc ~S"""
  Declarative auth wrapper and provider contract.

  `FastestMCP.Auth` does two jobs:

    * it is the value attached to a server definition when you call
      `FastestMCP.add_auth/3`
    * it is the behaviour that concrete auth providers implement

  Every provider is normalized behind the same contract so the rest of the
  runtime can stay transport-agnostic. In practice that means the provider can
  participate in three places:

    * `authenticate/3` verifies raw transport credentials and returns a
      normalized auth result
    * `http_dispatch/3` serves auth-owned HTTP endpoints, when the provider owns
      any
    * protected-resource metadata helpers describe the OAuth metadata surface

  ## Runtime Shape

  The runtime does not store provider-specific state directly on the context.
  Instead it stores a normalized `%FastestMCP.Auth.Result{}` with:

    * `principal`
    * `auth`
    * `capabilities`

  That keeps the rest of the execution path independent from whether the source
  was JWT, OIDC, static tokens, introspection, or a local OAuth server.
  """

  alias FastestMCP.Context
  alias FastestMCP.Error

  defstruct [:provider, options: %{}]

  @type input :: map()
  @type t :: %__MODULE__{provider: module(), options: map()}

  @callback authenticate(input(), Context.t(), map()) ::
              {:ok, Result.t() | map()} | {:error, Error.t() | atom() | {atom(), String.t()}}

  defmodule Result do
    @moduledoc """
    Normalized authentication result attached to the runtime context.
    """

    defstruct principal: nil, auth: %{}, capabilities: []

    @type t :: %__MODULE__{
            principal: any(),
            auth: map(),
            capabilities: [any()]
          }
  end

  @doc "Builds a new value for this module from the supplied options."
  def new(%__MODULE__{} = auth), do: validate!(auth)
  def new({provider, opts}), do: new(provider, opts)

  def new(provider, opts \\ []) when is_atom(provider) and (is_list(opts) or is_map(opts)) do
    %__MODULE__{provider: provider, options: Map.new(opts)}
    |> validate!()
  end

  @doc "Builds multiple normalized values."
  def new_many(providers) when is_list(providers), do: Enum.map(providers, &new/1)
  def new_many(provider), do: [new(provider)]

  @doc "Resolves the given input into the normalized runtime shape for this module."
  def resolve(nil, %Context{} = context, _input), do: {:ok, context}

  def resolve(%__MODULE__{} = auth, %Context{} = context, input) do
    auth_input = normalize_input(input)

    try do
      case auth.provider.authenticate(auth_input, context, auth.options) do
        {:ok, result} ->
          {:ok, Context.put_auth_result(context, normalize_result(result))}

        {:error, reason} ->
          {:error, normalize_error(reason, auth.provider)}

        other ->
          raise ArgumentError,
                "auth provider #{inspect(auth.provider)} must return {:ok, result} or {:error, reason}, got: #{inspect(other)}"
      end
    rescue
      error ->
        {:error,
         %Error{
           code: :internal_error,
           message: "auth provider #{inspect(auth.provider)} failed",
           details: %{kind: inspect(error.__struct__), reason: Exception.message(error)}
         }}
    end
  end

  @doc "Extracts the auth result stored on the context."
  def result_from_context(%Context{} = context) do
    %Result{
      principal: context.principal,
      auth: normalize_map(context.auth),
      capabilities: normalize_capabilities(context.capabilities)
    }
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(nil, _conn, _http_context), do: :pass

  def http_dispatch(%__MODULE__{} = auth, conn, http_context) do
    if function_exported?(auth.provider, :http_dispatch, 3) do
      auth.provider.http_dispatch(conn, http_context, auth.options)
    else
      :pass
    end
  end

  @doc "Returns the protected-resource metadata path for this auth configuration."
  def protected_resource_metadata_path(http_context) do
    "/.well-known/oauth-protected-resource" <> resource_path(http_context)
  end

  @doc "Returns the protected-resource metadata URL for this auth configuration."
  def protected_resource_metadata_url(nil, _http_context), do: nil

  def protected_resource_metadata_url(%__MODULE__{} = auth, http_context) do
    cond do
      function_exported?(auth.provider, :protected_resource_metadata, 2) ->
        join_absolute_url(http_context.base_url, protected_resource_metadata_path(http_context))

      true ->
        nil
    end
  end

  @doc "Builds the WWW-Authenticate header value for an auth error."
  def www_authenticate(nil, %Error{} = error, _http_context) do
    default_www_authenticate(error)
  end

  def www_authenticate(%__MODULE__{} = auth, %Error{} = error, http_context) do
    if function_exported?(auth.provider, :www_authenticate, 3) do
      auth.provider.www_authenticate(error, http_context, auth.options)
    else
      case protected_resource_metadata_url(auth, http_context) do
        nil ->
          default_www_authenticate(error)

        metadata_url ->
          default_www_authenticate(challenge_error(error)) <>
            ~s(, resource_metadata="#{escape_header_value(metadata_url)}")
      end
    end
  end

  @doc "Builds an OAuth-friendly HTTP error payload when the provider supports it."
  def oauth_http_error_payload(nil, _error, _http_context), do: nil

  def oauth_http_error_payload(
        %__MODULE__{} = auth,
        %Error{code: :unauthorized} = error,
        http_context
      ) do
    case protected_resource_metadata_url(auth, http_context) do
      nil ->
        nil

      _metadata_url ->
        %{
          "error" => "invalid_token",
          "error_description" => enhanced_invalid_token_description(error)
        }
    end
  end

  def oauth_http_error_payload(
        %__MODULE__{} = auth,
        %Error{code: :forbidden} = error,
        http_context
      ) do
    case protected_resource_metadata_url(auth, http_context) do
      nil ->
        nil

      _metadata_url ->
        %{
          "error" => "insufficient_scope",
          "error_description" => to_string(error.message)
        }
    end
  end

  def oauth_http_error_payload(_auth, _error, _http_context), do: nil

  defp validate!(%__MODULE__{provider: provider} = auth) do
    unless Code.ensure_loaded?(provider) and function_exported?(provider, :authenticate, 3) do
      raise ArgumentError,
            "auth provider #{inspect(provider)} must export authenticate/3"
    end

    auth
  end

  defp normalize_result(%Result{} = result) do
    %Result{
      principal: result.principal,
      auth: normalize_map(result.auth),
      capabilities: normalize_capabilities(result.capabilities)
    }
  end

  defp normalize_result(result) when is_map(result) do
    %Result{
      principal: fetch_field(result, :principal),
      auth: normalize_map(fetch_field(result, :auth, %{})),
      capabilities: normalize_capabilities(fetch_field(result, :capabilities, []))
    }
  end

  defp normalize_result(other) do
    raise ArgumentError,
          "auth provider result must be a map or FastestMCP.Auth.Result, got: #{inspect(other)}"
  end

  defp normalize_error(%Error{} = error, _provider), do: error

  defp normalize_error({code, message}, provider) when is_atom(code) and is_binary(message) do
    %Error{code: code, message: message, details: %{provider: inspect(provider)}}
  end

  defp normalize_error(code, provider) when code in [:unauthorized, :forbidden] do
    %Error{
      code: code,
      message: Atom.to_string(code) |> String.replace("_", " "),
      details: %{provider: inspect(provider)}
    }
  end

  defp normalize_error(reason, provider) do
    %Error{
      code: :internal_error,
      message: "auth provider #{inspect(provider)} failed",
      details: %{reason: inspect(reason), provider: inspect(provider)}
    }
  end

  defp normalize_input(nil), do: %{}
  defp normalize_input(input) when is_map(input), do: input
  defp normalize_input(input) when is_list(input), do: Enum.into(input, %{})

  defp normalize_capabilities(capabilities) when is_list(capabilities), do: capabilities
  defp normalize_capabilities(nil), do: []
  defp normalize_capabilities(capability), do: List.wrap(capability)

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  defp default_www_authenticate(%Error{} = error) do
    ~s(Bearer error="#{bearer_error_code(error)}", error_description="#{escape_header_value(error.message)}")
  end

  defp challenge_error(%Error{code: :unauthorized} = error) do
    %Error{error | message: enhanced_invalid_token_description(error)}
  end

  defp challenge_error(error), do: error

  defp bearer_error_code(%Error{code: :forbidden}), do: "insufficient_scope"
  defp bearer_error_code(_error), do: "invalid_token"

  defp enhanced_invalid_token_description(%Error{} = error) do
    base =
      case String.trim(to_string(error.message || "")) do
        "" -> "Authentication failed."
        message -> message
      end

    base <>
      " The provided bearer token is invalid, expired, or no longer recognized by the server. To resolve: clear authentication tokens in your MCP client and reconnect. Your client should automatically re-register and obtain new tokens."
  end

  defp resource_path(http_context) do
    base_path =
      http_context.base_url
      |> to_string()
      |> URI.parse()
      |> Map.get(:path)
      |> normalize_optional_path()

    mcp_base_path = normalize_path(Map.get(http_context, :mcp_base_path, "/mcp"))

    cond do
      base_path == "" ->
        mcp_base_path

      mcp_base_path == base_path ->
        mcp_base_path

      String.starts_with?(mcp_base_path, base_path <> "/") ->
        mcp_base_path

      true ->
        normalize_path(base_path <> "/" <> String.trim_leading(mcp_base_path, "/"))
    end
  end

  defp join_absolute_url(base_url, path) do
    URI.merge(base_url <> "/", path)
    |> URI.to_string()
  end

  defp normalize_optional_path(nil), do: ""
  defp normalize_optional_path(""), do: ""
  defp normalize_optional_path("/"), do: ""
  defp normalize_optional_path(path), do: normalize_path(path)

  defp normalize_path(path) do
    "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")
  end

  defp escape_header_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp fetch_field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
