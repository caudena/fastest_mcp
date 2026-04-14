defmodule FastestMCP.Auth.AssentFlow do
  @moduledoc """
  Small wrapper around Assent authorization-code strategies.
  This keeps provider-specific OAuth/OIDC flows behind one FastestMCP-owned
  seam while defaulting JWT handling to `Assent.JWTAdapter.JOSE`.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  defstruct [:strategy, config: []]

  @type t :: %__MODULE__{strategy: module(), config: Keyword.t()}

  @doc "Builds a new value for this module from the supplied options."
  def new(strategy, opts \\ []) when is_atom(strategy) and is_list(opts) do
    validate_strategy!(strategy)

    %__MODULE__{
      strategy: strategy,
      config: Keyword.put_new(opts, :jwt_adapter, Assent.JWTAdapter.JOSE)
    }
  end

  @doc "Builds the browser authorization URL for the current flow."
  def authorize_url(%__MODULE__{} = flow, params \\ []) when is_list(params) do
    flow.config
    |> merge_authorization_params(params)
    |> flow.strategy.authorize_url()
  end

  @doc "Normalizes callback parameters returned from the authorization server."
  def callback(%__MODULE__{} = flow, params, session_params \\ %{}) when is_map(params) do
    flow.config
    |> Keyword.put(:session_params, Map.new(session_params))
    |> flow.strategy.callback(params)
  end

  defp merge_authorization_params(config, params) do
    existing = config |> Keyword.get(:authorization_params, []) |> Enum.into(%{})
    merged = Map.merge(existing, Enum.into(params, %{}))
    Keyword.put(config, :authorization_params, Enum.into(merged, []))
  end

  defp validate_strategy!(strategy) do
    unless Code.ensure_loaded?(strategy) and function_exported?(strategy, :authorize_url, 1) and
             function_exported?(strategy, :callback, 2) do
      raise ArgumentError,
            "assent strategy #{inspect(strategy)} must export authorize_url/1 and callback/2"
    end
  end
end
