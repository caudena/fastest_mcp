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
    * `audiences` (verified resource audiences)
    * `scopes` (verified granted scopes)

  That keeps the rest of the execution path independent from whether the source
  was a Phoenix assign, Plug middleware, static token, or application-owned
  authenticator.
  """

  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Protocol.Redactor

  defstruct [:provider, options: %{}]

  @type input :: map()
  @type t :: %__MODULE__{provider: module(), options: map()}

  @callback authenticate(input(), Context.t(), map()) ::
              {:ok, Result.t() | map()} | {:error, Error.t() | atom() | {atom(), String.t()}}

  defmodule Result do
    @moduledoc """
    Normalized authentication result attached to the runtime context.

    `audiences` and `scopes` are claims the authenticator has actually
    validated. Protected HTTP resources reject successful-looking results that
    do not prove the configured resource and required scopes.

    The older `verified_audiences` and `verified_scopes` names remain accepted
    as compatibility aliases. New authenticators should use the canonical
    fields; contradictory canonical and compatibility values are rejected.
    """

    defstruct principal: nil,
              auth: %{},
              capabilities: [],
              audiences: [],
              scopes: [],
              verified_audiences: nil,
              verified_scopes: nil

    @type t :: %__MODULE__{
            principal: any(),
            auth: map(),
            capabilities: [any()],
            audiences: [String.t()],
            scopes: [String.t()],
            verified_audiences: [String.t()] | nil,
            verified_scopes: [String.t()] | nil
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
             audiences:
               resolve_assign_option(Map.get(opts, :audiences, []), value, input, context),
             scopes: resolve_assign_option(Map.get(opts, :scopes, []), value, input, context),
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
          result = normalize_result(result)

          with :ok <- validate_protected_resource_evidence(result, auth_input) do
            {:ok, Context.put_auth_result(context, result)}
          end

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
    audiences = normalize_verified_values!(context.verified_audiences, :audiences)
    scopes = normalize_verified_values!(context.verified_scopes, :scopes)

    %Result{
      principal: context.principal,
      auth: normalize_map(context.auth),
      capabilities: normalize_capabilities(context.capabilities),
      audiences: audiences,
      scopes: scopes,
      verified_audiences: audiences,
      verified_scopes: scopes
    }
  end

  @doc false
  def identity_fingerprint(principal, auth) do
    {principal, normalize_map(auth)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("auth-sha256:" <> &1))
  end

  @doc "Returns a stable fingerprint derived only from a verified principal."
  def principal_fingerprint(nil) do
    raise ArgumentError, "principal fingerprint requires a non-nil verified principal"
  end

  def principal_fingerprint(principal) do
    principal
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("principal-sha256:" <> &1))
  end

  @doc false
  def authorization_partition(%Context{} = context) do
    context
    |> result_from_context()
    |> authorization_partition()
    |> Map.put(:authenticated, context.authenticated)
  end

  def authorization_partition(%Result{} = result) do
    result = normalize_result(result)

    %{
      authenticated: true,
      principal:
        if(is_nil(result.principal),
          do: :missing,
          else: principal_fingerprint(result.principal)
        ),
      auth_digest: redacted_digest(result.auth),
      capabilities: result.capabilities |> Redactor.redact() |> deterministic_digest(),
      verified_audiences: Enum.sort(result.audiences),
      verified_scopes: Enum.sort(result.scopes)
    }
  end

  def authorization_partition(context) when is_map(context) do
    audiences = fetch_field(context, :verified_audiences, fetch_field(context, :audiences, []))
    scopes = fetch_field(context, :verified_scopes, fetch_field(context, :scopes, []))

    %Result{
      principal: fetch_field(context, :principal),
      auth: fetch_field(context, :auth, %{}),
      capabilities: fetch_field(context, :capabilities, []),
      audiences: audiences,
      scopes: scopes
    }
    |> authorization_partition()
    |> Map.put(:authenticated, fetch_field(context, :authenticated, false))
  end

  defp redacted_digest(value) do
    value
    |> Redactor.redact()
    |> deterministic_digest()
  end

  defp deterministic_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("sha256:" <> &1))
  end

  @doc "Builds the WWW-Authenticate header value for an auth error."
  def www_authenticate(nil, %Error{} = error, http_context) do
    protected_or_default_www_authenticate(error, http_context)
  end

  def www_authenticate(%__MODULE__{}, %Error{} = error, http_context) do
    protected_or_default_www_authenticate(error, http_context)
  end

  @doc false
  def validated_missing_scopes(%Error{code: :forbidden, details: details})
      when is_map(details) do
    case fetch_field(details, :missing_scopes, []) do
      scopes when is_list(scopes) and scopes != [] ->
        if Enum.all?(scopes, &valid_scope_token?/1) do
          scopes |> Enum.uniq() |> Enum.sort()
        else
          []
        end

      _other ->
        []
    end
  end

  def validated_missing_scopes(%Error{}), do: []

  defp validate!(%__MODULE__{provider: provider} = auth) do
    unless Code.ensure_loaded?(provider) and function_exported?(provider, :authenticate, 3) do
      raise ArgumentError,
            "authenticator #{inspect(provider)} must export authenticate/3"
    end

    auth
  end

  defp normalize_result(%Result{} = result) do
    audiences =
      normalize_evidence_pair(
        result.audiences,
        result.verified_audiences,
        :audiences,
        :verified_audiences
      )

    scopes =
      normalize_evidence_pair(result.scopes, result.verified_scopes, :scopes, :verified_scopes)

    %Result{
      principal: result.principal,
      auth: normalize_map(result.auth),
      capabilities: normalize_capabilities(result.capabilities),
      audiences: audiences,
      scopes: scopes,
      verified_audiences: audiences,
      verified_scopes: scopes
    }
  end

  defp normalize_result(result) when is_map(result) do
    audiences =
      normalize_evidence_pair(
        fetch_field(result, :audiences, []),
        fetch_field(result, :verified_audiences),
        :audiences,
        :verified_audiences
      )

    scopes =
      normalize_evidence_pair(
        fetch_field(result, :scopes, []),
        fetch_field(result, :verified_scopes),
        :scopes,
        :verified_scopes
      )

    %Result{
      principal: fetch_field(result, :principal),
      auth: normalize_map(fetch_field(result, :auth, %{})),
      capabilities: normalize_capabilities(fetch_field(result, :capabilities, [])),
      audiences: audiences,
      scopes: scopes,
      verified_audiences: audiences,
      verified_scopes: scopes
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

  defp normalize_verified_values!(nil, _field), do: []

  defp normalize_verified_values!(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      Enum.uniq(values)
    else
      raise ArgumentError, "#{field} must be a list of non-empty strings"
    end
  end

  defp normalize_verified_values!(value, _field) when is_binary(value) and value != "",
    do: [value]

  defp normalize_verified_values!(_value, field) do
    raise ArgumentError, "#{field} must be a list of non-empty strings"
  end

  defp normalize_evidence_pair(canonical, compatibility, canonical_field, compatibility_field) do
    canonical = normalize_verified_values!(canonical, canonical_field)

    case compatibility do
      value when value in [nil, []] ->
        canonical

      value ->
        compatibility = normalize_verified_values!(value, compatibility_field)

        cond do
          canonical == [] -> compatibility
          canonical == compatibility -> canonical
          true -> raise ArgumentError, "#{canonical_field} conflicts with #{compatibility_field}"
        end
    end
  end

  defp validate_protected_resource_evidence(%Result{} = result, auth_input) do
    expected_resource = fetch_field(auth_input, :expected_resource)
    expected_scopes = fetch_field(auth_input, :expected_scopes, [])

    cond do
      not is_binary(expected_resource) or expected_resource == "" ->
        :ok

      expected_resource not in result.audiences ->
        {:error,
         %Error{
           code: :unauthorized,
           message: "access token audience is not valid for this protected resource"
         }}

      not valid_expected_scopes?(expected_scopes) ->
        {:error,
         %Error{
           code: :internal_error,
           message: "protected resource expected scopes are invalid"
         }}

      true ->
        missing_scopes = Enum.uniq(expected_scopes) -- result.scopes

        if missing_scopes == [] do
          :ok
        else
          {:error,
           %Error{
             code: :forbidden,
             message: "access token does not grant the required scopes",
             details: %{missing_scopes: missing_scopes}
           }}
        end
    end
  end

  defp valid_expected_scopes?(scopes) when is_list(scopes) do
    Enum.all?(scopes, &(is_binary(&1) and &1 != ""))
  end

  defp valid_expected_scopes?(_scopes), do: false

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  @doc false
  def default_www_authenticate(%Error{} = error) do
    [~s(error="#{bearer_error_code(error)}")]
    |> maybe_append_scope(validated_missing_scopes(error))
    |> Kernel.++([~s(error_description="#{escape_header_value(error.message)}")])
    |> then(&("Bearer " <> Enum.join(&1, ", ")))
  end

  defp protected_or_default_www_authenticate(%Error{} = error, http_context) do
    case fetch_field(normalize_map(http_context), :protected_resource) do
      %ProtectedResource{} = protected_resource ->
        baseline_scopes =
          fetch_field(
            http_context,
            :expected_scopes,
            protected_resource.required_scopes
          )

        missing_scopes = validated_missing_scopes(error)

        challenge_scopes =
          case missing_scopes do
            [] -> List.wrap(baseline_scopes)
            scopes -> Enum.uniq(scopes)
          end

        ProtectedResource.www_authenticate(protected_resource,
          scopes: challenge_scopes,
          error: error,
          error_description: error.message
        )

      _other ->
        default_www_authenticate(error)
    end
  end

  defp bearer_error_code(%Error{code: :forbidden}), do: "insufficient_scope"
  defp bearer_error_code(_error), do: "invalid_token"

  defp maybe_append_scope(parameters, []), do: parameters

  defp maybe_append_scope(parameters, scopes) do
    parameters ++ [~s(scope="#{Enum.join(scopes, " ")}")]
  end

  defp valid_scope_token?(value) when is_binary(value) and value != "" do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == 0x21 or byte in 0x23..0x5B or byte in 0x5D..0x7E end)
  end

  defp valid_scope_token?(_value), do: false

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
