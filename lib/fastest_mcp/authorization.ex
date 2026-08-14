defmodule FastestMCP.Authorization do
  @moduledoc """
  Component-level authorization checks layered on top of authentication.

  Checks run after authentication has resolved verified authorization evidence
  onto the shared context. Unauthorized components are filtered from list
  operations and rejected with `:forbidden` on direct access.
  """

  alias FastestMCP.Component
  alias FastestMCP.Context, as: RuntimeContext
  alias FastestMCP.Error, as: RuntimeError
  alias FastestMCP.Operation

  defmodule Context do
    @moduledoc """
    Authorization-only view of the runtime context used by authorization checks.
    """

    defstruct [
      :principal,
      :component,
      :method,
      :server_name,
      :session_id,
      :transport,
      :target,
      authenticated: false,
      auth: %{},
      capabilities: [],
      verified_audiences: [],
      verified_scopes: [],
      arguments: %{},
      captures: %{},
      request_metadata: %{}
    ]

    @type t :: %__MODULE__{
            principal: any(),
            component: struct(),
            method: String.t(),
            server_name: String.t(),
            session_id: String.t() | nil,
            transport: atom(),
            target: String.t() | nil,
            authenticated: boolean(),
            auth: map(),
            capabilities: [any()],
            verified_audiences: [String.t()],
            verified_scopes: [String.t()],
            arguments: map(),
            captures: map(),
            request_metadata: map()
          }
  end

  defmodule Check do
    @moduledoc """
    Tagged authorization check.

    Scope checks retain enough structure for the HTTP boundary to produce an
    `insufficient_scope` challenge. Capability and application checks remain
    opaque so their denial details cannot leak through component discovery.
    """

    @enforce_keys [:kind, :value]
    defstruct [:kind, :value]

    @type t :: %__MODULE__{
            kind: :scopes | :capabilities | :opaque,
            value: MapSet.t(String.t()) | {:resolver, (Context.t() -> any())} | function()
          }
  end

  defmodule Error do
    @moduledoc """
    Exception raised when an authorization declaration is invalid.
    """

    defexception [:message]
  end

  @type check_result :: boolean() | :ok | {:error, String.t()}
  @type check :: (Context.t() -> check_result) | Check.t()

  @doc "Transforms input into the normalized runtime representation used by this module."
  def transform(checks, opts \\ []) when is_list(opts) do
    normalized = normalize(checks)
    mode = Keyword.get(opts, :mode, :prepend)

    fn component, _operation ->
      if Map.has_key?(component, :authorization) do
        %{component | authorization: merge_checks(normalized, component.authorization, mode)}
      else
        component
      end
    end
  end

  @doc "Normalizes input into the runtime shape expected by this module."
  def normalize(nil), do: []

  def normalize(checks) when is_list(checks) do
    Enum.map(checks, &normalize_check!/1)
  end

  def normalize(check) do
    [normalize_check!(check)]
  end

  @doc "Applies authorization checks to a component for the current operation."
  def authorize_component(component, %RuntimeContext{} = context, %Operation{} = operation) do
    checks = Map.get(component, :authorization, [])

    if checks == [] do
      :ok
    else
      auth_context = from_operation(component, context, operation)

      case evaluate_checks(checks, auth_context) do
        :ok ->
          :ok

        {:error, :missing_scopes, missing_scopes} ->
          {:error,
           %RuntimeError{
             code: :forbidden,
             message: "access token does not grant the required scopes",
             details: %{missing_scopes: missing_scopes}
           }}

        {:error, :denied} ->
          {:error,
           %RuntimeError{
             code: :forbidden,
             message: generic_denial_message(component),
             details: %{authorization_denial: :opaque}
           }}
      end
    end
  end

  @doc "Runs authorization checks against the current context."
  def run_checks([], %Context{}), do: true

  def run_checks(checks, %Context{} = context) when is_list(checks) do
    Enum.reduce_while(checks, true, fn check, _acc ->
      case run_public_check(normalize_check!(check), context) do
        true -> {:cont, true}
        false -> {:halt, false}
      end
    end)
  end

  def run_checks(check, %Context{} = context) do
    run_checks(normalize(check), context)
  end

  @doc "Builds a scope-based authorization rule."
  def require_scopes(resolver) when is_function(resolver, 1) do
    %Check{kind: :scopes, value: {:resolver, resolver}}
  end

  def require_scopes(scope) when not is_list(scope), do: require_scopes([scope])

  def require_scopes(scopes) when is_list(scopes) do
    %Check{kind: :scopes, value: normalize_oauth_tokens!(scopes, "required scopes")}
  end

  def require_scopes(first_scope, more_scopes) do
    require_scopes([first_scope | List.wrap(more_scopes)])
  end

  @doc "Builds a capability-based authorization rule."
  def require_capabilities(capability) when not is_list(capability),
    do: require_capabilities([capability])

  def require_capabilities(capabilities) when is_list(capabilities) do
    required = capabilities |> Enum.map(&to_string/1) |> MapSet.new()
    %Check{kind: :capabilities, value: required}
  end

  def require_capabilities(first_capability, more_capabilities) do
    require_capabilities([first_capability | List.wrap(more_capabilities)])
  end

  @doc "Builds a tag-based authorization rule."
  def restrict_tag(tag, opts \\ []) do
    restricted_tag = to_string(tag)
    scopes = Keyword.get(opts, :scopes, [restricted_tag])
    required = normalize_oauth_tokens!(List.wrap(scopes), "required scopes")

    resolver = fn %Context{component: component} ->
      tags =
        component
        |> Map.get(:tags, MapSet.new())
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      if MapSet.member?(tags, restricted_tag), do: MapSet.to_list(required), else: []
    end

    %Check{kind: :scopes, value: {:resolver, resolver}}
  end

  defp normalize_check!(%Check{} = check), do: check
  defp normalize_check!(check) when is_function(check, 1), do: %Check{kind: :opaque, value: check}

  defp normalize_check!(check) do
    raise ArgumentError,
          "authorization checks must be tagged checks or functions with arity 1, got: #{inspect(check)}"
  end

  defp from_operation(component, %RuntimeContext{} = context, %Operation{} = operation) do
    %Context{
      principal: context.principal,
      auth: Map.get(context, :auth, %{}),
      capabilities: Map.get(context, :capabilities, []),
      component: component,
      method: operation.method,
      server_name: context.server_name,
      session_id: context.session_id,
      transport: context.transport,
      target: operation.target,
      authenticated: Map.get(context, :authenticated, false),
      verified_audiences: Map.get(context, :verified_audiences, []),
      verified_scopes: Map.get(context, :verified_scopes, []),
      arguments: Map.get(operation, :arguments, %{}),
      captures: Map.get(operation, :captures, %{}),
      request_metadata: Map.get(context, :request_metadata, %{})
    }
  end

  defp evaluate_checks(checks, %Context{} = context) do
    checks
    |> Enum.map(&normalize_check!/1)
    |> Enum.reduce(%{missing_scopes: MapSet.new(), opaque_denial?: false}, fn check, result ->
      evaluate_check(check, context, result)
    end)
    |> then(fn
      %{opaque_denial?: true} ->
        {:error, :denied}

      %{missing_scopes: missing} ->
        if MapSet.size(missing) == 0 do
          :ok
        else
          {:error, :missing_scopes, missing |> MapSet.to_list() |> Enum.sort()}
        end
    end)
  end

  defp evaluate_check(%Check{kind: :scopes, value: value}, context, result) do
    case resolve_required_scopes(value, context) do
      {:ok, required} ->
        available =
          if context.authenticated do
            normalize_oauth_tokens!(context.verified_scopes, "verified scopes")
          else
            MapSet.new()
          end

        missing = MapSet.difference(required, available)
        %{result | missing_scopes: MapSet.union(result.missing_scopes, missing)}

      :error ->
        %{result | opaque_denial?: true}
    end
  rescue
    _error -> %{result | opaque_denial?: true}
  catch
    _kind, _reason -> %{result | opaque_denial?: true}
  end

  defp evaluate_check(%Check{kind: :capabilities, value: required}, context, result) do
    available = context.capabilities |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

    if MapSet.subset?(required, available),
      do: result,
      else: %{result | opaque_denial?: true}
  rescue
    _error -> %{result | opaque_denial?: true}
  end

  defp evaluate_check(%Check{kind: :opaque, value: check}, context, result) do
    if safe_check(check, context), do: result, else: %{result | opaque_denial?: true}
  end

  defp resolve_required_scopes(%MapSet{} = required, _context), do: {:ok, required}

  defp resolve_required_scopes({:resolver, resolver}, context) do
    {:ok, normalize_oauth_tokens!(List.wrap(resolver.(context)), "resolved required scopes")}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp run_public_check(%Check{kind: :scopes} = check, context) do
    case evaluate_checks([check], context) do
      :ok -> true
      _error -> false
    end
  end

  defp run_public_check(%Check{kind: :capabilities} = check, context) do
    case evaluate_checks([check], context) do
      :ok -> true
      _error -> false
    end
  end

  defp run_public_check(%Check{kind: :opaque, value: check}, context) do
    try do
      case check.(context) do
        true -> true
        :ok -> true
        false -> false
        nil -> false
        {:error, message} when is_binary(message) -> raise Error, message: message
        _other -> false
      end
    rescue
      error in Error ->
        reraise error, __STACKTRACE__

      _error ->
        false
    catch
      _kind, _reason ->
        false
    end
  end

  defp safe_check(check, %Context{} = context) do
    try do
      case check.(context) do
        true -> true
        :ok -> true
        _other -> false
      end
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  defp normalize_oauth_tokens!(tokens, label) when is_list(tokens) do
    normalized = Enum.map(tokens, &normalize_oauth_token!/1)

    Enum.each(normalized, fn token ->
      unless valid_oauth_scope_token?(token) do
        raise ArgumentError, "#{label} must contain valid non-empty OAuth scope tokens"
      end
    end)

    MapSet.new(normalized)
  end

  defp valid_oauth_scope_token?(token) when is_binary(token) and token != "" do
    token
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == 0x21 or byte in 0x23..0x5B or byte in 0x5D..0x7E end)
  end

  defp valid_oauth_scope_token?(_token), do: false

  defp normalize_oauth_token!(token) when is_binary(token), do: token
  defp normalize_oauth_token!(token) when is_atom(token), do: Atom.to_string(token)

  defp normalize_oauth_token!(_token) do
    raise ArgumentError, "OAuth scope tokens must be strings or atoms"
  end

  defp generic_denial_message(component) do
    "not authorized to access #{Component.type(component)} #{inspect(Component.identifier(component))}"
  end

  defp merge_checks(normalized, _existing, :replace), do: normalized
  defp merge_checks(normalized, existing, :append), do: normalize(existing) ++ normalized
  defp merge_checks(normalized, existing, :prepend), do: normalized ++ normalize(existing)
end
