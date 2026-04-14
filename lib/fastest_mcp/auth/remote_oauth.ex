defmodule FastestMCP.Auth.RemoteOAuth do
  @moduledoc """
  Resource-server auth provider with optional Assent-backed authorization routes.

  This provider delegates bearer verification to a configured token verifier while
  also exposing:

  - RFC 9728 protected-resource metadata
  - optional `/oauth/authorize` and `/oauth/callback` routes backed by Assent
  """

  @behaviour FastestMCP.Auth

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.StateStore
  alias FastestMCP.Error

  @oauth_state_cookie "_fastest_mcp_oauth_state"

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    verifier_auth = nested_auth(opts)

    case Auth.resolve(verifier_auth, context, input) do
      {:ok, context} ->
        {:ok, Auth.result_from_context(context)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    %{
      resource: resource_url(http_context),
      authorization_servers:
        opts
        |> opt(:authorization_servers, [])
        |> Enum.map(&to_string/1),
      scopes_supported:
        opts
        |> opt(:supported_scopes, opt(opts, :required_scopes, []))
        |> List.wrap()
    }
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    cond do
      conn.request_path == Auth.protected_resource_metadata_path(http_context) ->
        {:handled, send_json(conn, 200, protected_resource_metadata(http_context, opts))}

      flow_enabled?(opts) and conn.request_path == authorize_path(opts) ->
        handle_authorize(conn, http_context, opts)

      flow_enabled?(opts) and conn.request_path == callback_path(opts) ->
        handle_callback(conn, http_context, opts)

      true ->
        :pass
    end
  end

  defp handle_authorize(conn, http_context, opts) do
    flow = oauth_flow(opts, http_context)

    authorization_params =
      conn.query_params
      |> Map.drop(["state"])
      |> Enum.into([])

    case AssentFlow.authorize_url(flow, authorization_params) do
      {:ok, %{url: url, session_params: session_params}} ->
        state =
          Map.get(session_params, "state") || Map.get(session_params, :state) || random_state()

        with :ok <- store_oauth_state(http_context, state, session_params) do
          conn =
            conn
            |> put_resp_cookie(@oauth_state_cookie, encode_state_cookie(state),
              http_only: true,
              same_site: "Lax",
              path: "/"
            )
            |> put_resp_header("location", url)
            |> send_resp(302, "")

          {:handled, conn}
        end

      {:error, reason} ->
        {:error, normalize_assent_error(reason)}
    end
  end

  defp handle_callback(conn, http_context, opts) do
    with {:ok, expected_state} <- decode_state_cookie(conn.cookies[@oauth_state_cookie]),
         :ok <- validate_state(conn.query_params, expected_state),
         {:ok, stored_state} <- take_oauth_state(http_context, expected_state),
         {:ok, result} <-
           AssentFlow.callback(
             oauth_flow(opts, http_context),
             conn.query_params,
             Map.get(stored_state, "session_params", %{})
           ) do
      conn =
        conn
        |> delete_resp_cookie(@oauth_state_cookie, path: "/")
        |> send_json(200, %{result: result})

      {:handled, conn}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, normalize_assent_error(reason)}
    end
  end

  defp nested_auth(opts) do
    token_verifier =
      case opt(opts, :token_verifier) do
        nil -> raise ArgumentError, "remote oauth auth requires :token_verifier"
        token_verifier -> token_verifier
      end

    auth = Auth.new(token_verifier)
    %Auth{auth | options: Map.merge(auth.options, nested_required_scope_options(opts))}
  end

  defp nested_required_scope_options(opts) do
    case opt(opts, :required_scopes) do
      nil -> %{}
      [] -> %{}
      scopes -> %{required_scopes: List.wrap(scopes)}
    end
  end

  defp oauth_flow(opts, http_context) do
    case opt(opts, :oauth_flow) || opt(opts, :flow) do
      %AssentFlow{} = flow ->
        put_default_redirect(flow, http_context, opts)

      {strategy, flow_opts} ->
        strategy
        |> AssentFlow.new(flow_opts)
        |> put_default_redirect(http_context, opts)

      nil ->
        raise ArgumentError, "remote oauth auth requires :oauth_flow when auth routes are enabled"
    end
  end

  defp put_default_redirect(%AssentFlow{} = flow, http_context, opts) do
    config = Keyword.put_new(flow.config, :redirect_uri, callback_url(http_context, opts))
    %{flow | config: config}
  end

  defp normalize_assent_error(%Error{} = error), do: error

  defp normalize_assent_error(reason) do
    %Error{
      code: :bad_request,
      message: "oauth flow failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp authorize_path(opts), do: normalize_path(opt(opts, :authorize_path, "/oauth/authorize"))
  defp callback_path(opts), do: normalize_path(opt(opts, :callback_path, "/oauth/callback"))

  defp callback_url(http_context, opts) do
    join_url(http_context.base_url, callback_path(opts))
  end

  defp resource_url(http_context) do
    join_url(http_context.base_url, http_context.mcp_base_path)
  end

  defp random_state do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp validate_state(params, %{"state" => expected_state}) do
    if Map.get(params, "state") == expected_state do
      :ok
    else
      {:error, %Error{code: :bad_request, message: "oauth state mismatch"}}
    end
  end

  defp validate_state(params, expected_state) when is_binary(expected_state) do
    if Map.get(params, "state") == expected_state do
      :ok
    else
      {:error, %Error{code: :bad_request, message: "oauth state mismatch"}}
    end
  end

  defp decode_state_cookie(nil) do
    {:error, %Error{code: :bad_request, message: "missing oauth session"}}
  end

  defp decode_state_cookie(cookie) do
    with {:ok, decoded} <- Base.url_decode64(cookie, padding: false) do
      {:ok, decoded}
    else
      _ -> {:error, %Error{code: :bad_request, message: "invalid oauth session"}}
    end
  end

  defp encode_state_cookie(state), do: Base.url_encode64(state, padding: false)

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp flow_enabled?(opts), do: not is_nil(opt(opts, :oauth_flow) || opt(opts, :flow))

  defp join_url(base_url, path) do
    URI.merge(base_url <> "/", String.trim_leading(path, "/"))
    |> URI.to_string()
  end

  defp normalize_path(path) do
    "/" <> String.trim_leading(to_string(path), "/")
  end

  defp store_oauth_state(%{oauth_state_store: nil}, _state, _session_params) do
    {:error, %Error{code: :internal_error, message: "oauth state store is not available"}}
  end

  defp store_oauth_state(http_context, state, session_params) do
    StateStore.put(http_context.oauth_state_store, state, %{
      "session_params" => Map.new(session_params)
    })
  end

  defp take_oauth_state(%{oauth_state_store: nil}, _state) do
    {:error, %Error{code: :internal_error, message: "oauth state store is not available"}}
  end

  defp take_oauth_state(http_context, state) do
    case StateStore.take(http_context.oauth_state_store, state) do
      {:ok, stored_state} ->
        {:ok, stored_state}

      {:error, :not_found} ->
        {:error, %Error{code: :bad_request, message: "oauth session expired or missing"}}
    end
  end

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
