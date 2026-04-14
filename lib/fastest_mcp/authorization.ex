defmodule FastestMCP.Authorization do
  @moduledoc """
  Component-level authorization checks layered on top of authentication.

  Checks run after auth has resolved a principal and capabilities onto the
  shared context. Unauthorized components are filtered from list operations and
  rejected with `:forbidden` on direct access.
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
      auth: %{},
      capabilities: [],
      request_metadata: %{}
    ]

    @type t :: %__MODULE__{
            principal: any(),
            component: struct(),
            method: String.t(),
            server_name: String.t(),
            session_id: String.t(),
            transport: atom(),
            auth: map(),
            capabilities: [any()],
            request_metadata: map()
          }
  end

  defmodule Error do
    @moduledoc """
    Exception raised when an authorization declaration is invalid.
    """

    defexception [:message]
  end

  @type check_result :: boolean() | :ok | {:error, String.t()}
  @type check :: (Context.t() -> check_result)

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

      case run_checks(checks, auth_context) do
        true ->
          :ok

        false ->
          {:error,
           %RuntimeError{
             code: :forbidden,
             message:
               "not authorized to access #{Component.type(component)} #{inspect(Component.identifier(component))}"
           }}
      end
    end
  rescue
    error in Error ->
      {:error, %RuntimeError{code: :forbidden, message: error.message}}
  end

  @doc "Runs authorization checks against the current context."
  def run_checks([], %Context{}), do: true

  def run_checks(checks, %Context{} = context) when is_list(checks) do
    Enum.reduce_while(checks, true, fn check, _acc ->
      case run_check(check, context) do
        true -> {:cont, true}
        false -> {:halt, false}
      end
    end)
  end

  def run_checks(check, %Context{} = context) do
    run_checks(normalize(check), context)
  end

  @doc "Builds a scope-based authorization rule."
  def require_scopes(scope) when not is_list(scope), do: require_scopes([scope])

  def require_scopes(scopes) when is_list(scopes) do
    required =
      scopes
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    fn %Context{capabilities: capabilities} ->
      available =
        capabilities
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      MapSet.subset?(required, available)
    end
  end

  def require_scopes(first_scope, more_scopes) do
    required =
      [first_scope | List.wrap(more_scopes)]
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    fn %Context{capabilities: capabilities} ->
      available =
        capabilities
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      MapSet.subset?(required, available)
    end
  end

  @doc "Builds a tag-based authorization rule."
  def restrict_tag(tag, opts \\ []) do
    restricted_tag = to_string(tag)
    scopes = Keyword.get(opts, :scopes, [restricted_tag])
    scoped_check = require_scopes(scopes)

    fn %Context{component: component} = context ->
      tags =
        component
        |> Map.get(:tags, MapSet.new())
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      if MapSet.member?(tags, restricted_tag), do: scoped_check.(context), else: true
    end
  end

  defp normalize_check!(check) when is_function(check, 1), do: check

  defp normalize_check!(check) do
    raise ArgumentError,
          "authorization checks must be functions with arity 1, got: #{inspect(check)}"
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
      request_metadata: Map.get(context, :request_metadata, %{})
    }
  end

  defp run_check(check, %Context{} = context) do
    try do
      case check.(context) do
        true -> true
        :ok -> true
        false -> false
        nil -> false
        {:error, message} when is_binary(message) -> raise Error, message: message
        other -> other not in [false, nil]
      end
    rescue
      error in Error ->
        reraise error, __STACKTRACE__

      _error ->
        false
    end
  end

  defp merge_checks(normalized, _existing, :replace), do: normalized
  defp merge_checks(normalized, existing, :append), do: normalize(existing) ++ normalized
  defp merge_checks(normalized, existing, :prepend), do: normalized ++ normalize(existing)
end
