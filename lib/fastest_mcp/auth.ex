defmodule FastestMCP.Auth do
  @moduledoc ~S"""
  Declarative auth wrapper and authenticator contract.

  `FastestMCP.Auth` does two jobs:

    * it is the value attached to a server definition when you call
      `FastestMCP.add_auth/3`
    * it is the behaviour that concrete authenticators implement

  Every authenticator is normalized behind the same contract so the rest of the
  runtime can stay transport-agnostic:

    * `authenticate/3` verifies raw transport credentials and returns a
      normalized auth result

  ## Runtime Shape

  The runtime does not store provider-specific state directly on the context.
  Instead it stores a normalized `%FastestMCP.Auth.Result{}` with:

    * `principal`
    * `auth`
    * `capabilities`

  That keeps the rest of the execution path independent from whether the source
  was a Phoenix assign, Plug middleware, static token, or application-owned
  authenticator.
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

  defmodule FunctionProvider do
    @moduledoc false
    @behaviour FastestMCP.Auth

    def authenticate(input, context, %{handler: handler}) when is_function(handler, 2) do
      handler.(input, context)
    end

    def authenticate(input, context, %{handler: handler} = opts) when is_function(handler, 3) do
      handler.(input, context, Map.delete(opts, :handler))
    end
  end

  @doc "Builds a new value for this module from the supplied options."
  def new(provider_or_auth, opts \\ [])
  def new(%__MODULE__{} = auth, _opts), do: validate!(auth)
  def new({provider, opts}, _opts), do: new(provider, opts)

  def new(provider, opts) when is_function(provider, 2) or is_function(provider, 3) do
    %__MODULE__{provider: FunctionProvider, options: Map.put(Map.new(opts), :handler, provider)}
    |> validate!()
  end

  def new(provider, opts) when is_atom(provider) and (is_list(opts) or is_map(opts)) do
    %__MODULE__{provider: provider, options: Map.new(opts)}
    |> validate!()
  end

  @doc """
  Builds an authenticator from one Plug/Phoenix assign.

  The HTTP transport can copy selected `conn.assigns` into auth input under
  `"assigns"`. This helper turns one assign value into the normalized auth
  result used by the runtime.
  """
  def from_assign(assign, opts \\ []) when is_atom(assign) and (is_list(opts) or is_map(opts)) do
    opts = Map.new(opts)
    assign_name = Atom.to_string(assign)

    fn input, context ->
      assigns = fetch_field(input, :assigns, %{})

      case fetch_assign(assigns, assign, assign_name) do
        {:ok, value} when not is_nil(value) ->
          {:ok,
           %Result{
             principal:
               resolve_assign_option(Map.get(opts, :principal, value), value, input, context),
             capabilities:
               resolve_assign_option(Map.get(opts, :capabilities, []), value, input, context),
             auth:
               resolve_assign_option(
                 Map.get(opts, :auth, %{source: :assign, assign: assign}),
                 value,
                 input,
                 context
               )
           }}

        _other ->
          {:error,
           %Error{
             code: :unauthorized,
             message: "missing auth assign #{inspect(assign)}"
           }}
      end
    end
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
                "authenticator #{inspect(auth.provider)} must return {:ok, result} or {:error, reason}, got: #{inspect(other)}"
      end
    rescue
      error ->
        {:error,
         %Error{
           code: :internal_error,
           message: "authenticator #{inspect(auth.provider)} failed",
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

  @doc "Builds the WWW-Authenticate header value for an auth error."
  def www_authenticate(nil, %Error{} = error, _http_context) do
    default_www_authenticate(error)
  end

  def www_authenticate(%__MODULE__{}, %Error{} = error, _http_context) do
    default_www_authenticate(error)
  end

  defp validate!(%__MODULE__{provider: provider} = auth) do
    unless Code.ensure_loaded?(provider) and function_exported?(provider, :authenticate, 3) do
      raise ArgumentError,
            "authenticator #{inspect(provider)} must export authenticate/3"
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
          "authenticator result must be a map or FastestMCP.Auth.Result, got: #{inspect(other)}"
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
      message: "authenticator #{inspect(provider)} failed",
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

  defp bearer_error_code(%Error{code: :forbidden}), do: "insufficient_scope"
  defp bearer_error_code(_error), do: "invalid_token"

  defp escape_header_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp fetch_field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp fetch_assign(assigns, atom_key, string_key) when is_map(assigns) do
    cond do
      Map.has_key?(assigns, atom_key) -> {:ok, Map.fetch!(assigns, atom_key)}
      Map.has_key?(assigns, string_key) -> {:ok, Map.fetch!(assigns, string_key)}
      true -> :error
    end
  end

  defp fetch_assign(_assigns, _atom_key, _string_key), do: :error

  defp resolve_assign_option(fun, value, _input, _context) when is_function(fun, 1),
    do: fun.(value)

  defp resolve_assign_option(fun, value, _input, context) when is_function(fun, 2),
    do: fun.(value, context)

  defp resolve_assign_option(fun, value, input, context) when is_function(fun, 3),
    do: fun.(value, input, context)

  defp resolve_assign_option(value, _assign, _input, _context), do: value
end
