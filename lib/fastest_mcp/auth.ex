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

  import FastestMCP.Util, only: [string_keys: 1]

  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Redactor
  alias FastestMCP.URIPolicy

  # Options can hold credentials, such as the tokens of `StaticToken`, so
  # inspect output, and with it crash and supervisor reports, leaves them out.
  @derive {Inspect, except: [:options]}
  defstruct [:provider, options: %{}]

  @type input :: map()
  @type t :: %__MODULE__{provider: module(), options: map()}

  @callback authenticate(input(), Context.t(), map()) ::
              {:ok, __MODULE__.Result.t() | map()}
              | {:error, Error.t() | atom() | {atom(), String.t()}}

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

  @doc """
  Builds an authenticator from a module implementing this behaviour and its
  options, a `{module, opts}` tuple, or a function of the auth input and the
  context (a 3-arity function also receives `opts` as a map).
  """
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
  result used by the runtime. A request whose assign is missing or `nil` fails
  with `:unauthorized` and the message `missing or invalid credentials`.
  """
  def from_assign(assign, opts \\ []) when is_atom(assign) and (is_list(opts) or is_map(opts)) do
    opts = Map.new(opts)
    assign_name = Atom.to_string(assign)

    fn input, context ->
      case input do
        %{"assigns" => %{^assign_name => value}} when not is_nil(value) ->
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

        # The message names no assign: clients receive it.
        _other ->
          {:error, %Error{code: :unauthorized, message: "missing or invalid credentials"}}
      end
    end
  end

  @doc """
  Authenticates `input` and stores the result on `context`: `{:ok, context}` or
  `{:error, %FastestMCP.Error{}}`. A nil authenticator returns the context
  unchanged.
  """
  def resolve(nil, %Context{} = context, _input), do: {:ok, context}

  def resolve(%__MODULE__{} = auth, %Context{} = context, input) do
    auth_input = normalize_input(input)

    with {:ok, result} <- authenticate(auth, auth_input, context),
         :ok <- validate_protected_resource_evidence(result, auth_input) do
      {:ok, Context.put_auth_result(context, result)}
    end
  end

  # The authenticator is application code: it may raise, throw, exit, or
  # return a malformed result, which fails authentication with an internal
  # error.
  defp authenticate(%__MODULE__{provider: provider} = auth, input, context) do
    case provider.authenticate(input, context, auth.options) do
      {:ok, result} ->
        {:ok, normalize_result(result)}

      {:error, reason} ->
        {:error, normalize_error(reason, auth)}

      other ->
        message =
          "#{subject(auth)} must return {:ok, result} or {:error, reason}, got: #{inspect(other)}"

        {:error, failure(subject(auth), :error, %ArgumentError{message: message}, [])}
    end
  catch
    kind, reason -> {:error, failure(subject(auth), kind, reason, __STACKTRACE__)}
  end

  # Clients see the module of an authenticator, which belongs to the
  # application, but not the one that runs a function.
  defp subject(%__MODULE__{provider: FunctionProvider}), do: "authenticator"
  defp subject(%__MODULE__{provider: provider}), do: "authenticator #{inspect(provider)}"

  @doc false
  # An authentication that raised, threw, or exited, with what `catch kind,
  # reason` received. The exception is kept as the cause, for logs and spans:
  # a throw or an exit as the `ErlangError` the BEAM makes of an uncaught
  # throw, `{:nocatch, value}`, or `{:exit, reason}`. Its message can hold the
  # auth input, as a `KeyError` on the input does, and with it credentials, so
  # clients get neither: they get "<subject> failed" and the exception's kind,
  # or "authentication failed" with `mask_error_details: true`.
  def failure(subject, kind, reason, stacktrace) do
    exception =
      case kind do
        :error -> Exception.normalize(:error, reason, stacktrace)
        :throw -> %ErlangError{original: {:nocatch, reason}}
        :exit -> %ErlangError{original: {:exit, reason}}
      end

    %Error{
      code: :internal_error,
      message: "#{subject} failed",
      details: %{kind: inspect(exception.__struct__)},
      exposure: masked_failure(),
      cause: {exception, stacktrace}
    }
  end

  defp masked_failure, do: %{mask_error_details: true, message: "authentication failed"}

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
  # The first of the `names` claims in the principal or auth map of an auth
  # result: application data, with atom or string keys, that handlers see as
  # the authenticator returned it.
  def claim(claims, names) when is_map(claims),
    do: Enum.find_value(names, &(Map.get(claims, &1) || Map.get(claims, Atom.to_string(&1))))

  def claim(_claims, _names), do: nil

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
    %Result{
      principal: Map.get(context, :principal),
      auth: Map.get(context, :auth, %{}),
      capabilities: Map.get(context, :capabilities, []),
      audiences: Map.get(context, :verified_audiences, Map.get(context, :audiences, [])),
      scopes: Map.get(context, :verified_scopes, Map.get(context, :scopes, []))
    }
    |> authorization_partition()
    |> Map.put(:authenticated, Map.get(context, :authenticated, false))
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

  @doc """
  Builds the WWW-Authenticate header value for an auth error. The challenge
  of a request that sent no credentials (`credentials?: false` in
  `http_context`) carries no error code, as RFC 6750 asks.
  """
  def www_authenticate(auth, %Error{} = error, http_context)
      when is_nil(auth) or is_struct(auth, __MODULE__) do
    if error.code == :unauthorized and Map.get(http_context, :credentials?) == false,
      do: challenge(nil, http_context),
      else: challenge(error, http_context)
  end

  @doc false
  # Runs `fun`, which authenticates the request of `context` and returns
  # `{:ok, value}` or `{:error, %FastestMCP.Error{}}`, between the
  # `[:fastest_mcp, :auth, :start]` event and its `:stop` or `:exception` event.
  def span(%__MODULE__{provider: provider}, %Context{} = context, metadata, fun) do
    metadata = Map.put(metadata, :auth_provider, inspect(provider))
    started_at = System.monotonic_time()
    Context.emit(context, [:auth, :start], %{system_time: System.system_time()}, metadata)
    result = fun.()
    duration = %{duration: System.monotonic_time() - started_at}

    case result do
      {:error, %Error{} = error} ->
        failure = Map.merge(metadata, failure_metadata(error))
        Context.emit(context, [:auth, :exception], duration, failure)

      {:ok, _value} ->
        Context.emit(context, [:auth, :stop], duration, metadata)
    end

    result
  end

  # An exception the authenticator raised is there as `:telemetry.span/3`
  # reports one: `kind`, `reason`, and `stacktrace`.
  defp failure_metadata(%Error{} = error) do
    failure = %{code: error.code, error: Exception.message(error)}

    case error.cause do
      {exception, stacktrace} ->
        Map.merge(failure, %{kind: :error, reason: exception, stacktrace: stacktrace})

      nil ->
        failure
    end
  end

  @doc false
  def validated_missing_scopes(%Error{code: :forbidden} = error) do
    case Error.detail(error, :missing_scopes) do
      scopes when is_list(scopes) and scopes != [] ->
        if Enum.all?(scopes, &URIPolicy.scope_token?/1) do
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

  # An authenticator returns a `Result` or a map with atom or string keys.
  defp normalize_result(result) when is_map(result) do
    result = string_keys(result)

    audiences =
      normalize_evidence_pair(
        Map.get(result, "audiences", []),
        result["verified_audiences"],
        :audiences,
        :verified_audiences
      )

    scopes =
      normalize_evidence_pair(
        Map.get(result, "scopes", []),
        result["verified_scopes"],
        :scopes,
        :verified_scopes
      )

    %Result{
      principal: result["principal"],
      auth: normalize_map(Map.get(result, "auth", %{})),
      capabilities: normalize_capabilities(Map.get(result, "capabilities", [])),
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

  defp normalize_error(%Error{} = error, _auth), do: error

  defp normalize_error({code, message}, _auth) when is_atom(code) and is_binary(message),
    do: %Error{code: code, message: message}

  defp normalize_error(code, _auth) when code in [:unauthorized, :forbidden],
    do: %Error{code: code, message: Atom.to_string(code)}

  defp normalize_error(reason, auth) do
    %Error{
      code: :internal_error,
      message: "#{subject(auth)} failed",
      details: %{reason: inspect(reason)},
      exposure: masked_failure()
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

  # The HTTP transport puts the protected resource in the auth input.
  defp validate_protected_resource_evidence(%Result{} = result, auth_input) do
    expected_resource = auth_input["expected_resource"]
    expected_scopes = Map.get(auth_input, "expected_scopes", [])

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
    |> Kernel.++([~s(error_description="#{URIPolicy.quote_value(error.message)}")])
    |> then(&("Bearer " <> Enum.join(&1, ", ")))
  end

  # The challenge for `error`, or without an error for nil.
  defp challenge(
         error,
         %{protected_resource: %ProtectedResource{} = protected_resource} = http_context
       ) do
    scopes =
      case error && validated_missing_scopes(error) do
        missing_scopes when missing_scopes not in [nil, []] ->
          missing_scopes

        _none ->
          List.wrap(Map.get(http_context, :expected_scopes, protected_resource.required_scopes))
      end

    ProtectedResource.www_authenticate(protected_resource,
      scopes: scopes,
      error: error,
      error_description: error && error.message
    )
  end

  defp challenge(nil, _http_context), do: "Bearer"
  defp challenge(error, _http_context), do: default_www_authenticate(error)

  defp bearer_error_code(%Error{code: :forbidden}), do: "insufficient_scope"
  defp bearer_error_code(_error), do: "invalid_token"

  defp maybe_append_scope(parameters, []), do: parameters

  defp maybe_append_scope(parameters, scopes) do
    parameters ++ [~s(scope="#{Enum.join(scopes, " ")}")]
  end

  defp resolve_assign_option(fun, value, _input, _context) when is_function(fun, 1),
    do: fun.(value)

  defp resolve_assign_option(fun, value, _input, context) when is_function(fun, 2),
    do: fun.(value, context)

  defp resolve_assign_option(fun, value, input, context) when is_function(fun, 3),
    do: fun.(value, input, context)

  defp resolve_assign_option(value, _assign, _input, _context), do: value
end
