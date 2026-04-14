defmodule FastestMCP.Auth.LocalOAuth do
  @moduledoc """
  In-process OAuth provider that protects MCP operations and mounts a local
  authorization server surface for hermetic parity tests.

  It supports:

  - RFC 9728 protected-resource metadata
  - OAuth authorization-server metadata
  - dynamic client registration
  - authorization-code exchange
  - refresh-token rotation
  - token revocation
  """

  @behaviour FastestMCP.Auth

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.CIMD
  alias FastestMCP.Auth.JWTIssuer
  alias FastestMCP.Auth.PrivateKeyJWT
  alias FastestMCP.Auth.RedirectURI
  alias FastestMCP.Auth.Result
  alias FastestMCP.Auth.StateStore
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime

  @authorization_grant_types ["authorization_code", "refresh_token"]
  @response_types ["code"]
  @token_endpoint_auth_methods ["none", "client_secret_post", "client_secret_basic"]
  @pkce_methods ["plain", "S256"]
  @consent_csrf_cookie "FASTEST_MCP_OAUTH_CONSENT"
  @denied_clients_cookie "MCP_DENIED_CLIENTS"

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    required_scopes = required_scopes(opts)

    with {:ok, token} <- fetch_bearer_token(input),
         {:ok, runtime} <- fetch_runtime(context.server_name),
         {:ok, access_token} <- StateStore.get(access_token_store(runtime, opts), token),
         :ok <- validate_upstream_token(access_token, context, opts),
         :ok <- ensure_required_scopes(access_token, required_scopes) do
      {:ok, build_auth_result(token, access_token)}
    else
      {:error, :missing_credentials} ->
        {:error, %Error{code: :unauthorized, message: "missing credentials"}}

      {:error, :not_found} ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to authenticate oauth token",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    %{
      resource: resource_url(http_context),
      authorization_servers: [authorization_server_issuer(http_context, opts)],
      scopes_supported: scopes_for_metadata(opts)
    }
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    cond do
      conn.method == "GET" and
          conn.request_path == Auth.protected_resource_metadata_path(http_context) ->
        {:handled, send_json(conn, 200, protected_resource_metadata(http_context, opts))}

      conn.method == "GET" and
          conn.request_path == authorization_server_metadata_path(http_context, opts) ->
        {:handled, send_json(conn, 200, authorization_server_metadata(http_context, opts))}

      conn.method == "POST" and conn.request_path == registration_path(opts) ->
        handle_registration(conn, http_context, opts)

      conn.method == "GET" and conn.request_path == authorize_path(opts) ->
        handle_authorize(conn, http_context, opts)

      consent_enabled?(opts) and conn.method == "GET" and conn.request_path == consent_path(opts) ->
        handle_consent_page(conn, http_context, opts)

      consent_enabled?(opts) and conn.method == "POST" and conn.request_path == consent_path(opts) ->
        handle_consent_submit(conn, http_context, opts)

      oauth_proxy_enabled?(opts) and conn.method in ["GET", "POST"] and
          conn.request_path == callback_path(opts) ->
        handle_proxy_callback(conn, http_context, opts)

      conn.method == "POST" and conn.request_path == token_path(opts) ->
        handle_token(conn, http_context, opts)

      conn.method == "POST" and conn.request_path == revoke_path(opts) ->
        handle_revoke(conn, http_context, opts)

      true ->
        :pass
    end
  end

  defp handle_registration(conn, http_context, opts) do
    with {:ok, conn, params} <- read_request_params(conn),
         {:ok, client} <- register_client(http_context, params, opts) do
      {:handled, send_json(conn, 201, client)}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_oauth_error(conn, status, payload, headers)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handle_authorize(conn, http_context, opts) do
    case authorize_client(http_context, conn.query_params, opts) do
      {:ok, redirect_uri} ->
        {:handled,
         conn
         |> put_resp_header("location", redirect_uri)
         |> send_resp(302, "")}

      {:oauth_error, status, payload, headers} ->
        {:handled, send_authorize_error(conn, status, payload, headers)}
    end
  end

  defp handle_consent_page(conn, http_context, opts) do
    with {:ok, txn_id} <- require_query_param(conn.query_params, "txn_id"),
         {:ok, transaction} <- get_authorization_transaction(http_context, txn_id),
         {:ok, csrf_token, transaction} <-
           ensure_transaction_csrf(http_context, txn_id, transaction) do
      conn =
        conn
        |> put_resp_header("x-frame-options", "DENY")
        |> put_resp_cookie(@consent_csrf_cookie, encode_consent_cookie(txn_id, csrf_token),
          http_only: true,
          same_site: "Lax",
          secure: secure_cookie?(http_context),
          path: consent_path(opts)
        )
        |> put_resp_content_type("text/html")
        |> send_resp(200, render_consent_html(transaction, txn_id, csrf_token, opts))

      {:handled, conn}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_oauth_error(conn, status, payload, headers)}
    end
  end

  defp handle_consent_submit(conn, http_context, opts) do
    conn = fetch_cookies(conn)

    with {:ok, conn, params} <- read_request_params(conn),
         {:ok, txn_id} <- require_param(params, "txn_id"),
         {:ok, csrf_token} <- require_param(params, "csrf_token"),
         {:ok, action} <- require_param(params, "action"),
         {:ok, transaction} <- get_authorization_transaction(http_context, txn_id),
         :ok <- validate_consent_csrf(conn, txn_id, csrf_token, transaction),
         {:ok, redirect_uri, conn} <-
           consent_redirect(conn, http_context, opts, action, txn_id, transaction) do
      {:handled,
       conn
       |> clear_consent_cookie(opts)
       |> put_resp_header("location", redirect_uri)
       |> send_resp(302, "")}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_oauth_error(conn, status, payload, headers)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handle_proxy_callback(conn, http_context, opts) do
    with {:ok, conn, callback_params} <- read_callback_params(conn),
         {:ok, upstream_state} <- require_query_param(callback_params, "state"),
         {:ok, stored_context} <- take_upstream_authorization(http_context, opts, upstream_state),
         {:ok, result} <-
           AssentFlow.callback(
             upstream_oauth_flow(opts, http_context),
             callback_params,
             Map.get(stored_context, "session_params", %{})
           ),
         {:ok, code} <-
           store_authorization_code(
             http_context,
             %{"client_id" => stored_context["transaction"]["client_id"]},
             stored_context["transaction"]["redirect_uri"],
             %{
               "code_challenge" => stored_context["transaction"]["code_challenge"],
               "code_challenge_method" => stored_context["transaction"]["code_challenge_method"]
             },
             stored_context["transaction"]["scopes"],
             opts,
             upstream_authorization_metadata(result)
           ) do
      redirect_uri =
        build_redirect_uri(stored_context["transaction"]["redirect_uri"], %{
          "code" => code,
          "state" => stored_context["transaction"]["state"]
        })

      {:handled,
       conn
       |> put_resp_header("location", redirect_uri)
       |> send_resp(302, "")}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_oauth_error(conn, status, payload, headers)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:handled,
         send_oauth_error(
           conn,
           400,
           %{
             "error" => "invalid_grant",
             "error_description" => "upstream oauth callback failed",
             "details" => inspect(reason)
           },
           []
         )}
    end
  end

  defp handle_token(conn, http_context, opts) do
    with {:ok, conn, params} <- read_request_params(conn),
         {:ok, params} <- merge_client_auth(conn, params),
         {:ok, response} <- issue_token(http_context, params, opts) do
      {:handled, send_token_json(conn, 200, response)}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_token_error(conn, status, payload, headers)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handle_revoke(conn, http_context, opts) do
    with {:ok, conn, params} <- read_request_params(conn),
         {:ok, params} <- merge_client_auth(conn, params),
         :ok <- revoke_token(http_context, params, opts) do
      {:handled, send_token_json(conn, 200, %{})}
    else
      {:oauth_error, status, payload, headers} ->
        {:handled, send_token_error(conn, status, payload, headers)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp authorization_server_metadata(http_context, opts) do
    %{
      issuer: metadata_issuer(http_context),
      authorization_endpoint: join_url(http_context.base_url, authorize_path(opts)),
      token_endpoint: join_url(http_context.base_url, token_path(opts)),
      registration_endpoint: join_url(http_context.base_url, registration_path(opts)),
      revocation_endpoint: join_url(http_context.base_url, revoke_path(opts)),
      response_types_supported: @response_types,
      grant_types_supported: @authorization_grant_types,
      token_endpoint_auth_methods_supported: token_endpoint_auth_methods_supported(opts),
      code_challenge_methods_supported: @pkce_methods,
      scopes_supported: scopes_for_metadata(opts),
      client_id_metadata_document_supported: enable_cimd?(opts)
    }
    |> maybe_put(
      :token_endpoint_auth_signing_alg_values_supported,
      token_endpoint_auth_signing_alg_values_supported(opts)
    )
    |> maybe_put(:service_documentation, service_documentation_url(opts))
  end

  defp register_client(http_context, params, opts) do
    redirect_uri_pattern_source =
      if Map.has_key?(params, "allowed_redirect_uri_patterns") do
        Map.get(params, "allowed_redirect_uri_patterns")
      else
        opt(opts, :allowed_client_redirect_uris)
      end

    with {:ok, redirect_uris} <- validate_redirect_uris(Map.get(params, "redirect_uris")),
         {:ok, grant_types} <-
           validate_members(
             Map.get(params, "grant_types", @authorization_grant_types),
             @authorization_grant_types,
             "grant_types"
           ),
         {:ok, response_types} <-
           validate_members(
             Map.get(params, "response_types", @response_types),
             @response_types,
             "response_types"
           ),
         {:ok, token_endpoint_auth_method} <-
           validate_member(
             Map.get(params, "token_endpoint_auth_method", "none"),
             @token_endpoint_auth_methods,
             "token_endpoint_auth_method"
           ),
         {:ok, allowed_redirect_uri_patterns} <-
           validate_redirect_uri_patterns(redirect_uri_pattern_source),
         {:ok, scope} <- normalize_client_scope(params, opts) do
      client_id = Map.get(params, "client_id") || random_token("client")

      client_secret =
        case token_endpoint_auth_method do
          "none" -> nil
          _method -> Map.get(params, "client_secret") || random_token("secret")
        end

      client = %{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uris" => redirect_uris,
        "grant_types" => grant_types,
        "response_types" => response_types,
        "token_endpoint_auth_method" => token_endpoint_auth_method,
        "allowed_redirect_uri_patterns" => allowed_redirect_uri_patterns,
        "scope" => scope,
        "client_name" => Map.get(params, "client_name"),
        "client_id_issued_at" => System.os_time(:second),
        "client_secret_expires_at" => if(client_secret, do: 0, else: nil)
      }

      :ok = StateStore.put(client_store(http_context, opts), client_id, client, :infinity)
      {:ok, client}
    end
  end

  defp authorize_client(http_context, params, opts) do
    with {:ok, client} <-
           fetch_client(
             http_context,
             with_authorize_state(opts, Map.get(params, "state")),
             Map.get(params, "client_id")
           ),
         :ok <- ensure_authorize_response_type(params),
         {:ok, redirect_uri} <-
           validate_client_redirect_uri(client, Map.get(params, "redirect_uri"), opts),
         {:ok, scopes} <- authorize_scopes(client, params, opts) do
      if consent_enabled?(opts) do
        store_authorization_transaction(http_context, client, redirect_uri, params, scopes, opts)
      else
        with {:ok, code} <-
               store_authorization_code(http_context, client, redirect_uri, params, scopes, opts) do
          {:ok,
           build_redirect_uri(redirect_uri, %{"code" => code, "state" => Map.get(params, "state")})}
        end
      end
    else
      {:oauth_error, _status, _payload, _headers} = error ->
        error
    end
  end

  defp issue_token(http_context, params, opts) do
    with {:ok, client} <- authenticate_token_client(http_context, params, opts) do
      case Map.get(params, "grant_type") do
        "authorization_code" ->
          exchange_authorization_code(http_context, client, params, opts)

        "refresh_token" ->
          exchange_refresh_token(http_context, client, params, opts)

        nil ->
          oauth_error(:unsupported_grant_type, "grant_type is required")

        other ->
          oauth_error(:unsupported_grant_type, "unsupported grant type #{inspect(other)}")
      end
    end
  end

  defp exchange_authorization_code(http_context, client, params, opts) do
    with {:ok, code_record} <- load_authorization_code(http_context, Map.get(params, "code")),
         :ok <- validate_authorization_code_client(code_record, client),
         :ok <- validate_authorization_code_redirect(code_record, Map.get(params, "redirect_uri")),
         :ok <- validate_pkce(code_record, Map.get(params, "code_verifier")),
         {:ok, response} <-
           issue_token_pair(http_context, client, code_record["scopes"], opts, code_record) do
      {:ok, response}
    end
  end

  defp exchange_refresh_token(http_context, client, params, opts) do
    with {:ok, refresh_record} <-
           load_refresh_token(http_context, Map.get(params, "refresh_token")),
         :ok <- validate_refresh_token_client(refresh_record, client),
         {:ok, scopes} <- refresh_scopes(refresh_record, params),
         :ok <-
           revoke_refresh_and_access(
             http_context,
             Map.fetch!(params, "refresh_token"),
             refresh_record,
             opts
           ),
         {:ok, response} <-
           issue_token_pair(
             http_context,
             client,
             scopes,
             opts,
             metadata_from_token_record(refresh_record)
           ) do
      {:ok, response}
    end
  end

  defp revoke_token(http_context, params, opts) do
    with {:ok, token} <- require_param(params, "token"),
         {:ok, _client} <- authenticate_optional_revoke_client(http_context, params, opts) do
      access_store = access_token_store(http_context, opts)
      refresh_store = refresh_token_store(http_context, opts)

      case StateStore.get(access_store, token) do
        {:ok, access_record} ->
          :ok = revoke_access_and_refresh(http_context, token, access_record, opts)

        {:error, :not_found} ->
          case StateStore.get(refresh_store, token) do
            {:ok, refresh_record} ->
              :ok = revoke_refresh_and_access(http_context, token, refresh_record, opts)

            {:error, :not_found} ->
              :ok
          end
      end

      :ok
    else
      {:oauth_error, _status, _payload, _headers} = error -> error
    end
  end

  defp issue_token_pair(http_context, client, scopes, opts, metadata) do
    access_token_id = random_token("access")

    refresh_token_id =
      if(client_supports_refresh?(client), do: random_token("refresh"), else: nil)

    principal = Map.get(metadata, "principal") || principal_for(client)
    provider = normalize_provider(Map.get(metadata, "provider", "local_oauth"))
    auth_metadata = normalize_map(Map.get(metadata, "auth", %{}))
    jwt_issuer = jwt_issuer(http_context, opts)

    access_token =
      issue_access_token_value(
        jwt_issuer,
        client["client_id"],
        scopes,
        access_token_id,
        access_token_expires_in(http_context),
        upstream_claims_from_metadata(metadata)
      )

    refresh_token =
      issue_refresh_token_value(
        jwt_issuer,
        client,
        scopes,
        refresh_token_id,
        jwt_refresh_token_expires_in(http_context, opts),
        upstream_claims_from_metadata(metadata)
      )

    access_record = %{
      "client_id" => client["client_id"],
      "scopes" => scopes,
      "principal" => principal,
      "refresh_token" => refresh_token,
      "provider" => provider,
      "auth" => auth_metadata,
      "token_id" => access_token_id
    }

    refresh_record = %{
      "client_id" => client["client_id"],
      "scopes" => scopes,
      "principal" => principal,
      "access_token" => access_token,
      "provider" => provider,
      "auth" => auth_metadata,
      "token_id" => refresh_token_id
    }

    :ok =
      StateStore.put(
        access_token_store(http_context, opts),
        access_token,
        access_record,
        access_token_ttl_ms(http_context)
      )

    if refresh_token do
      :ok =
        StateStore.put(
          refresh_token_store(http_context, opts),
          refresh_token,
          refresh_record,
          refresh_token_ttl_ms(http_context)
        )
    end

    response =
      %{
        "access_token" => access_token,
        "token_type" => "Bearer",
        "expires_in" => access_token_expires_in(http_context),
        "scope" => scope_string(scopes)
      }
      |> maybe_put("refresh_token", refresh_token)

    {:ok, response}
  end

  defp store_authorization_code(
         http_context,
         client,
         redirect_uri,
         params,
         opts_scopes,
         opts,
         metadata \\ %{}
       ) do
    code = random_token("code")

    record =
      %{
        "client_id" => client["client_id"],
        "redirect_uri" => redirect_uri,
        "scopes" => opts_scopes,
        "code_challenge" => Map.get(params, "code_challenge"),
        "code_challenge_method" => Map.get(params, "code_challenge_method", "plain")
      }
      |> Map.merge(normalize_map(metadata))

    :ok = StateStore.put(authorization_code_store(http_context, opts), code, record)
    {:ok, code}
  end

  defp load_authorization_code(_http_context, nil) do
    oauth_error(:invalid_grant, "authorization code is required")
  end

  defp load_authorization_code(http_context, code) do
    case StateStore.take(authorization_code_store(http_context, %{}), code) do
      {:ok, code_record} ->
        {:ok, code_record}

      {:error, :not_found} ->
        oauth_error(:invalid_grant, "authorization code is invalid or expired")
    end
  end

  defp load_refresh_token(_http_context, nil) do
    oauth_error(:invalid_grant, "refresh token is required")
  end

  defp load_refresh_token(http_context, token) do
    case StateStore.get(refresh_token_store(http_context, %{}), token) do
      {:ok, refresh_record} ->
        {:ok, refresh_record}

      {:error, :not_found} ->
        oauth_error(:invalid_grant, "refresh token is invalid or expired")
    end
  end

  defp authenticate_token_client(http_context, params, opts) do
    with {:ok, client_id} <- require_client_id(params),
         {:ok, client} <- fetch_client(http_context, opts, client_id),
         :ok <- validate_client_secret(client, params, http_context, opts) do
      {:ok, client}
    end
  end

  defp authenticate_optional_revoke_client(_http_context, %{"client_id" => nil}, _opts),
    do: {:ok, nil}

  defp authenticate_optional_revoke_client(_http_context, %{}, _opts), do: {:ok, nil}

  defp authenticate_optional_revoke_client(http_context, params, opts) do
    authenticate_token_client(http_context, params, opts)
  end

  defp fetch_client(_http_context, _opts, nil) do
    oauth_error(:invalid_request, "client_id is required")
  end

  defp fetch_client(http_context, opts, client_id) do
    case StateStore.get(client_store(http_context, opts), client_id) do
      {:ok, client} ->
        {:ok, client}

      {:error, :not_found} ->
        maybe_fetch_cimd_client(http_context, opts, client_id)
    end
  end

  defp ensure_authorize_response_type(%{"response_type" => "code"}), do: :ok

  defp ensure_authorize_response_type(_params) do
    oauth_error(:unsupported_response_type, "only response_type=code is supported")
  end

  defp validate_client_redirect_uri(%{"cimd_document" => document} = client, nil, _opts) do
    with {:ok, redirect_uri} <- CIMD.default_redirect_uri(document),
         :ok <- validate_cimd_proxy_redirect(client, redirect_uri) do
      {:ok, redirect_uri}
    else
      {:error, :redirect_uri_required} ->
        oauth_error(
          :invalid_request,
          "redirect_uri must be specified when client metadata uses multiple or wildcard redirect_uris"
        )

      {:oauth_error, _status, _payload, _headers} = error ->
        error
    end
  end

  defp validate_client_redirect_uri(%{"cimd_document" => document} = client, redirect_uri, _opts)
       when is_binary(redirect_uri) do
    with {:ok, redirect_uri} <- CIMD.validate_redirect_uri(document, redirect_uri),
         :ok <- validate_cimd_proxy_redirect(client, redirect_uri) do
      {:ok, redirect_uri}
    else
      {:error, :invalid_redirect_uri} ->
        oauth_error(:invalid_request, "redirect_uri does not match client metadata document")

      {:error, :missing_redirect_uri} ->
        oauth_error(:invalid_request, "redirect_uri is required")

      {:oauth_error, _status, _payload, _headers} = error ->
        error
    end
  end

  defp validate_client_redirect_uri(client, nil, _opts) do
    case Map.get(client, "redirect_uris", []) do
      [redirect_uri] ->
        {:ok, redirect_uri}

      _ ->
        oauth_error(:invalid_request, "redirect_uri is required")
    end
  end

  defp validate_client_redirect_uri(client, redirect_uri, opts) when is_binary(redirect_uri) do
    allowed_patterns = Map.get(client, "allowed_redirect_uri_patterns")

    cond do
      not is_nil(allowed_patterns) and
          RedirectURI.validate_redirect_uri(redirect_uri, allowed_patterns) ->
        {:ok, redirect_uri}

      allowed_patterns not in [nil, []] ->
        oauth_error(:invalid_request, "redirect_uri does not match allowed patterns")

      oauth_proxy_enabled?(opts) and is_nil(allowed_patterns) ->
        {:ok, redirect_uri}

      redirect_uri in Map.get(client, "redirect_uris", []) ->
        {:ok, redirect_uri}

      true ->
        oauth_error(:invalid_request, "redirect_uri is not registered for this client")
    end
  end

  defp authorize_scopes(client, params, _opts) do
    requested_scopes =
      case parse_scope_string(Map.get(params, "scope")) do
        [] -> parse_scope_string(Map.get(client, "scope"))
        scopes -> scopes
      end

    client_scopes = parse_scope_string(Map.get(client, "scope"))

    cond do
      client_scopes == [] ->
        {:ok, requested_scopes}

      requested_scopes == [] ->
        {:ok, client_scopes}

      requested_scopes -- client_scopes == [] ->
        {:ok, requested_scopes}

      true ->
        oauth_error(:invalid_scope, "requested scopes exceed registered client scopes")
    end
  end

  defp validate_authorization_code_client(code_record, client) do
    if code_record["client_id"] == client["client_id"] do
      :ok
    else
      oauth_error(:invalid_grant, "authorization code belongs to a different client")
    end
  end

  defp validate_authorization_code_redirect(code_record, redirect_uri) do
    if code_record["redirect_uri"] == redirect_uri do
      :ok
    else
      oauth_error(:invalid_grant, "redirect_uri does not match the authorization code")
    end
  end

  defp validate_pkce(%{"code_challenge" => nil}, _code_verifier), do: :ok
  defp validate_pkce(%{"code_challenge" => ""}, _code_verifier), do: :ok

  defp validate_pkce(
         %{"code_challenge" => challenge, "code_challenge_method" => "S256"},
         code_verifier
       )
       when is_binary(code_verifier) do
    digest =
      :sha256
      |> :crypto.hash(code_verifier)
      |> Base.url_encode64(padding: false)

    if digest == challenge do
      :ok
    else
      oauth_error(:invalid_grant, "code_verifier does not match code_challenge")
    end
  end

  defp validate_pkce(%{"code_challenge" => challenge}, code_verifier)
       when is_binary(code_verifier) do
    if code_verifier == challenge do
      :ok
    else
      oauth_error(:invalid_grant, "code_verifier does not match code_challenge")
    end
  end

  defp validate_pkce(%{"code_challenge" => _challenge}, nil) do
    oauth_error(:invalid_grant, "code_verifier is required for this authorization code")
  end

  defp validate_refresh_token_client(refresh_record, client) do
    if refresh_record["client_id"] == client["client_id"] do
      :ok
    else
      oauth_error(:invalid_grant, "refresh token belongs to a different client")
    end
  end

  defp refresh_scopes(refresh_record, params) do
    original_scopes = normalize_scopes(refresh_record["scopes"])

    case parse_scope_string(Map.get(params, "scope")) do
      [] ->
        {:ok, original_scopes}

      requested ->
        if requested -- original_scopes == [] do
          {:ok, requested}
        else
          oauth_error(
            :invalid_scope,
            "requested scopes exceed those granted to the refresh token"
          )
        end
    end
  end

  defp revoke_access_and_refresh(http_context, token, access_record, opts) do
    :ok = StateStore.delete(access_token_store(http_context, opts), token)

    if refresh_token = Map.get(access_record, "refresh_token") do
      :ok = StateStore.delete(refresh_token_store(http_context, opts), refresh_token)
    end

    :ok
  end

  defp revoke_refresh_and_access(http_context, token, refresh_record, opts) do
    :ok = StateStore.delete(refresh_token_store(http_context, opts), token)

    if access_token = Map.get(refresh_record, "access_token") do
      :ok = StateStore.delete(access_token_store(http_context, opts), access_token)
    end

    :ok
  end

  defp ensure_required_scopes(_access_token, []), do: :ok

  defp ensure_required_scopes(access_token, required_scopes) do
    scopes = normalize_scopes(access_token["scopes"])
    missing_scopes = required_scopes -- scopes

    if missing_scopes == [] do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "insufficient scope",
         details: %{missing_scopes: missing_scopes}
       }}
    end
  end

  defp build_auth_result(token, access_token) do
    scopes = normalize_scopes(access_token["scopes"])
    provider = normalize_provider(Map.get(access_token, "provider", "local_oauth"))
    auth_metadata = normalize_map(Map.get(access_token, "auth", %{}))

    %Result{
      principal:
        Map.get(access_token, "principal") || %{"client_id" => access_token["client_id"]},
      auth:
        auth_metadata
        |> Map.put_new(:provider, provider)
        |> Map.put_new(:client_id, access_token["client_id"])
        |> Map.put_new(:token, token)
        |> Map.put_new(:token_type, "Bearer")
        |> Map.put_new(:scopes, scopes),
      capabilities: scopes
    }
  end

  defp validate_upstream_token(access_token, context, opts) do
    auth = normalize_map(Map.get(access_token, "auth", %{}))

    if oauth_proxy_record?(access_token, auth) and Map.has_key?(opts, :token_verifier) do
      with {:ok, verification_token} <- verification_token(auth, opts),
           {:ok, _verified_context} <-
             Auth.resolve(
               Auth.new(thread_http_client(Map.get(opts, :token_verifier), opts)),
               context,
               %{
                 "token" => verification_token
               }
             ) do
        :ok
      else
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp oauth_proxy_record?(access_token, auth) do
    Map.get(access_token, "provider") == "oauth_proxy" or
      Map.has_key?(auth, "upstream_access_token") or
      Map.has_key?(auth, "upstream_id_token")
  end

  defp thread_http_client({provider, verifier_opts}, opts)
       when is_atom(provider) and (is_map(verifier_opts) or is_list(verifier_opts)) do
    merged_opts =
      verifier_opts
      |> Map.new()
      |> put_http_option(:http_client, opt(opts, :http_client))
      |> put_http_option(:http_requester, opt(opts, :http_requester))

    {provider, merged_opts}
  end

  defp thread_http_client(token_verifier, _opts), do: token_verifier

  defp put_http_option(opts, _key, nil), do: opts
  defp put_http_option(opts, key, _value) when is_map_key(opts, key), do: opts
  defp put_http_option(opts, key, value), do: Map.put(opts, key, value)

  defp verification_token(auth, opts) do
    if Map.get(opts, :verify_id_token, false) do
      case Map.get(auth, "upstream_id_token") do
        token when is_binary(token) and token != "" -> {:ok, token}
        _other -> {:error, %Error{code: :unauthorized, message: "upstream id_token is missing"}}
      end
    else
      case Map.get(auth, "upstream_access_token") do
        token when is_binary(token) and token != "" ->
          {:ok, token}

        _other ->
          {:error, %Error{code: :unauthorized, message: "upstream access_token is missing"}}
      end
    end
  end

  defp normalize_client_scope(params, opts) do
    scope = Map.get(params, "scope") || default_scope_string(opts)
    supported_scopes = supported_scopes(opts)

    cond do
      scope in [nil, ""] ->
        {:ok, nil}

      supported_scopes == [] ->
        {:ok, scope_string(parse_scope_string(scope))}

      parse_scope_string(scope) -- supported_scopes == [] ->
        {:ok, scope_string(parse_scope_string(scope))}

      true ->
        oauth_error(:invalid_client_metadata, "requested scope is not supported by this server")
    end
  end

  defp validate_redirect_uris(redirect_uris)
       when is_list(redirect_uris) and redirect_uris != [] do
    normalized =
      Enum.map(redirect_uris, fn redirect_uri ->
        redirect_uri = to_string(redirect_uri)

        case URI.parse(redirect_uri) do
          %URI{scheme: nil} ->
            {:error, redirect_uri}

          %URI{host: nil, path: nil} ->
            {:error, redirect_uri}

          _uri ->
            {:ok, redirect_uri}
        end
      end)

    case Enum.find(normalized, &match?({:error, _}, &1)) do
      nil ->
        {:ok, Enum.map(normalized, fn {:ok, redirect_uri} -> redirect_uri end)}

      {:error, redirect_uri} ->
        oauth_error(:invalid_client_metadata, "redirect_uri #{inspect(redirect_uri)} is invalid")
    end
  end

  defp validate_redirect_uris(_redirect_uris) do
    oauth_error(:invalid_client_metadata, "redirect_uris must be a non-empty list")
  end

  defp validate_redirect_uri_patterns(nil), do: {:ok, nil}

  defp validate_redirect_uri_patterns(patterns) when is_list(patterns) do
    if Enum.all?(patterns, &(is_binary(&1) and &1 != "")) do
      {:ok, patterns}
    else
      oauth_error(
        :invalid_client_metadata,
        "allowed_redirect_uri_patterns must be a list of non-empty strings"
      )
    end
  end

  defp validate_redirect_uri_patterns(_patterns) do
    oauth_error(
      :invalid_client_metadata,
      "allowed_redirect_uri_patterns must be a list of non-empty strings"
    )
  end

  defp validate_members(value, allowed, field) do
    values = normalize_list(value)

    if values != [] and values -- allowed == [] do
      {:ok, values}
    else
      oauth_error(:invalid_client_metadata, "#{field} contains unsupported values")
    end
  end

  defp validate_member(value, allowed, field) when is_binary(value) do
    if value in allowed do
      {:ok, value}
    else
      oauth_error(:invalid_client_metadata, "#{field} is unsupported")
    end
  end

  defp validate_client_secret(
         %{"token_endpoint_auth_method" => "none"},
         _params,
         _http_context,
         _opts
       ),
       do: :ok

  defp validate_client_secret(
         %{
           "token_endpoint_auth_method" => "private_key_jwt",
           "client_id" => client_id,
           "cimd_document" => cimd_document
         },
         params,
         http_context,
         opts
       ) do
    with {:ok, assertion_type} <- require_param(params, "client_assertion_type"),
         :ok <- validate_client_assertion_type(assertion_type),
         {:ok, assertion} <- require_param(params, "client_assertion"),
         {:ok, _claims} <-
           PrivateKeyJWT.validate(
             assertion,
             client_id,
             join_url(http_context.base_url, token_path(opts)),
             cimd_document,
             transaction_store(http_context, opts),
             private_key_jwt_options(opts)
           ) do
      :ok
    else
      {:error, reason} when is_binary(reason) ->
        oauth_error(:invalid_client, reason)

      {:oauth_error, _status, _payload, _headers} = error ->
        error
    end
  end

  defp validate_client_secret(client, params, _http_context, _opts) do
    if Map.get(params, "client_secret") == client["client_secret"] do
      :ok
    else
      oauth_error(:invalid_client, "client_secret is invalid")
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> oauth_error(:invalid_request, "#{key} is required")
    end
  end

  defp require_client_id(params) do
    case Map.get(params, "client_id") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        oauth_error(:invalid_client, "client_id is required")
    end
  end

  defp merge_client_auth(conn, params) do
    case fetch_basic_auth(conn) do
      {:ok, {client_id, client_secret}} ->
        {:ok,
         params
         |> Map.put_new("client_id", client_id)
         |> Map.put_new("client_secret", client_secret)}

      :missing ->
        {:ok, params}

      {:error, reason} ->
        oauth_error(:invalid_client, reason)
    end
  end

  defp fetch_basic_auth(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded | _rest] ->
        decode_basic_auth(encoded)

      [_other | _rest] ->
        :missing

      [] ->
        :missing
    end
  end

  defp decode_basic_auth(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- String.split(decoded, ":", parts: 2),
         true <- client_id != "" do
      {:ok, {client_id, client_secret}}
    else
      _ ->
        {:error, "authorization header is not valid basic auth"}
    end
  end

  defp validate_client_assertion_type(assertion_type) do
    if assertion_type == PrivateKeyJWT.assertion_type() do
      :ok
    else
      oauth_error(:invalid_client, "client_assertion_type is invalid")
    end
  end

  defp read_request_params(conn) do
    content_type =
      conn |> get_req_header("content-type") |> List.first() |> normalize_content_type()

    with {:ok, body, conn} <- Plug.Conn.read_body(conn) do
      case content_type do
        "application/json" ->
          case Jason.decode(body) do
            {:ok, params} when is_map(params) ->
              {:ok, conn, params}

            {:ok, _other} ->
              oauth_error(:invalid_request, "json body must be an object")

            {:error, _error} ->
              oauth_error(:invalid_request, "request body must be valid json")
          end

        _other ->
          {:ok, conn, URI.decode_query(body)}
      end
    else
      {:more, _partial, _conn} ->
        oauth_error(:invalid_request, "request body is too large")

      {:error, reason} ->
        oauth_error(:invalid_request, "failed to read request body: #{inspect(reason)}")
    end
  end

  defp read_callback_params(%Plug.Conn{method: "GET"} = conn) do
    {:ok, conn, conn.query_params}
  end

  defp read_callback_params(%Plug.Conn{method: "POST"} = conn) do
    read_request_params(conn)
  end

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp send_oauth_error(conn, status, payload, headers) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, current ->
        put_resp_header(current, key, value)
      end)
      |> put_resp_header("cache-control", "no-store")

    send_json(conn, status, payload)
  end

  defp send_token_error(conn, status, payload, headers) do
    send_oauth_error(conn, status, payload, [{"pragma", "no-cache"} | headers])
  end

  defp send_token_json(conn, status, payload) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_json(status, payload)
  end

  defp oauth_error(error, description, extras \\ %{}, headers \\ []) do
    {:oauth_error, status_for_oauth_error(error),
     Map.merge(
       %{"error" => Atom.to_string(error), "error_description" => description},
       extras
     ), headers}
  end

  defp status_for_oauth_error(:invalid_client), do: 401
  defp status_for_oauth_error(_error), do: 400

  defp fetch_bearer_token(%{"authorization" => "Bearer " <> token}), do: {:ok, token}
  defp fetch_bearer_token(%{"token" => token}) when is_binary(token), do: {:ok, token}

  defp fetch_bearer_token(%{"headers" => %{"authorization" => "Bearer " <> token}}),
    do: {:ok, token}

  defp fetch_bearer_token(_input), do: {:error, :missing_credentials}

  defp build_redirect_uri(redirect_uri, params) do
    uri = URI.parse(redirect_uri)
    query = URI.decode_query(uri.query || "") |> Map.merge(compact_map(params))
    %{uri | query: URI.encode_query(query)} |> URI.to_string()
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp random_token(prefix) do
    encoded =
      24
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    prefix <> "_" <> encoded
  end

  defp metadata_issuer(http_context), do: normalize_url(http_context.base_url)

  defp authorization_server_issuer(http_context, opts) do
    opts
    |> opt(:issuer_url, http_context.base_url)
    |> normalize_url()
  end

  defp resource_url(http_context) do
    join_url(http_context.base_url, http_context.mcp_base_path)
  end

  defp jwt_issuer(http_context, opts) do
    case opt(opts, :jwt_signing_key) do
      nil ->
        nil

      signing_key ->
        JWTIssuer.new(
          issuer: metadata_issuer(http_context),
          audience: resource_url(http_context),
          signing_key: normalize_jwt_signing_key(signing_key)
        )
    end
  end

  defp authorization_server_metadata_path(http_context, opts) do
    case issuer_path(http_context, opts) do
      "" -> "/.well-known/oauth-authorization-server"
      path -> "/.well-known/oauth-authorization-server" <> path
    end
  end

  defp registration_path(opts), do: normalize_path(opt(opts, :registration_path, "/register"))
  defp authorize_path(opts), do: normalize_path(opt(opts, :authorize_path, "/authorize"))
  defp callback_path(opts), do: normalize_path(opt(opts, :callback_path, "/auth/callback"))
  defp token_path(opts), do: normalize_path(opt(opts, :token_path, "/token"))
  defp revoke_path(opts), do: normalize_path(opt(opts, :revoke_path, "/revoke"))

  defp client_store(http_context, opts),
    do: opt(opts, :client_store) || Map.fetch!(http_context, :oauth_client_store)

  defp authorization_code_store(http_context, opts),
    do:
      opt(opts, :authorization_code_store) ||
        Map.fetch!(http_context, :oauth_authorization_code_store)

  defp access_token_store(runtime_or_context, opts) when is_map(runtime_or_context) do
    opt(opts, :access_token_store) || Map.fetch!(runtime_or_context, :oauth_access_token_store)
  end

  defp refresh_token_store(http_context, opts),
    do: opt(opts, :refresh_token_store) || Map.fetch!(http_context, :oauth_refresh_token_store)

  defp access_token_ttl_ms(http_context),
    do: Map.get(http_context, :oauth_access_token_ttl_ms, 60 * 60_000)

  defp refresh_token_ttl_ms(http_context),
    do: Map.get(http_context, :oauth_refresh_token_ttl_ms, :infinity)

  defp access_token_expires_in(http_context), do: div(access_token_ttl_ms(http_context), 1000)

  defp jwt_refresh_token_expires_in(http_context, opts) do
    case refresh_token_ttl_ms(http_context) do
      :infinity -> opt(opts, :jwt_refresh_token_expires_in, 60 * 60 * 24 * 30)
      ttl_ms when is_integer(ttl_ms) -> div(ttl_ms, 1000)
    end
  end

  defp scopes_for_metadata(opts), do: supported_scopes(opts)

  defp supported_scopes(opts),
    do: normalize_scopes(opt(opts, :supported_scopes, required_scopes(opts)))

  defp required_scopes(opts), do: normalize_scopes(opt(opts, :required_scopes, []))

  defp default_scope_string(opts) do
    case supported_scopes(opts) do
      [] -> nil
      scopes -> scope_string(scopes)
    end
  end

  defp token_endpoint_auth_methods_supported(opts) do
    if enable_cimd?(opts) do
      @token_endpoint_auth_methods ++ ["private_key_jwt"]
    else
      @token_endpoint_auth_methods
    end
  end

  defp token_endpoint_auth_signing_alg_values_supported(opts) do
    if enable_cimd?(opts) do
      PrivateKeyJWT.supported_algorithms()
    else
      nil
    end
  end

  defp principal_for(client), do: %{"client_id" => client["client_id"]}

  defp client_supports_refresh?(client) do
    "refresh_token" in normalize_list(client["grant_types"])
  end

  defp scope_string([]), do: ""
  defp scope_string(scopes), do: Enum.join(scopes, " ")

  defp parse_scope_string(nil), do: []

  defp parse_scope_string(scope) when is_binary(scope) do
    scope
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_scopes(scope) when is_binary(scope), do: parse_scope_string(scope)
  defp normalize_scopes(nil), do: []

  defp normalize_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(nil), do: []

  defp issue_access_token_value(nil, _client_id, _scopes, token_id, _expires_in, _claims),
    do: token_id

  defp issue_access_token_value(
         jwt_issuer,
         client_id,
         scopes,
         token_id,
         expires_in,
         upstream_claims
       ) do
    JWTIssuer.issue_access_token(jwt_issuer,
      client_id: client_id,
      scopes: scopes,
      jti: token_id,
      expires_in: expires_in,
      upstream_claims: upstream_claims
    )
  end

  defp issue_refresh_token_value(nil, client, _scopes, token_id, _expires_in, _claims) do
    if client_supports_refresh?(client), do: token_id, else: nil
  end

  defp issue_refresh_token_value(
         jwt_issuer,
         client,
         scopes,
         token_id,
         expires_in,
         upstream_claims
       ) do
    if client_supports_refresh?(client) do
      JWTIssuer.issue_refresh_token(jwt_issuer,
        client_id: client["client_id"],
        scopes: scopes,
        jti: token_id,
        expires_in: expires_in,
        upstream_claims: upstream_claims
      )
    else
      nil
    end
  end

  defp upstream_claims_from_metadata(metadata) do
    auth = normalize_map(Map.get(metadata, "auth", %{}))

    cond do
      is_map(Map.get(metadata, "upstream_claims")) ->
        Map.get(metadata, "upstream_claims")

      is_map(Map.get(auth, "upstream_user")) ->
        Map.get(auth, "upstream_user")

      true ->
        nil
    end
  end

  defp normalize_jwt_signing_key(key) when is_binary(key) do
    case Base.url_decode64(key) do
      {:ok, decoded} when byte_size(decoded) == 32 ->
        key

      _ ->
        JWTIssuer.derive_jwt_key(
          low_entropy_material: key,
          salt: "fastestmcp-jwt-signing-key"
        )
    end
  end

  defp normalize_content_type(nil), do: "application/x-www-form-urlencoded"

  defp normalize_content_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp normalize_path(path) do
    "/" <> String.trim_leading(to_string(path), "/")
  end

  defp send_authorize_error(conn, status, payload, headers) do
    if wants_html?(conn) and payload["registration_endpoint"] do
      conn =
        Enum.reduce(headers, conn, fn {key, value}, current ->
          put_resp_header(current, key, value)
        end)
        |> put_resp_header("cache-control", "no-store")

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(status, render_authorize_error_html(payload))
    else
      send_oauth_error(conn, status, payload, headers)
    end
  end

  defp join_url(base_url, path) do
    URI.merge(base_url <> "/", String.trim_leading(path, "/"))
    |> URI.to_string()
  end

  defp join_absolute_url(base_url, path) do
    URI.merge(base_url <> "/", path)
    |> URI.to_string()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp require_query_param(params, key), do: require_param(params, key)

  defp store_authorization_transaction(http_context, client, redirect_uri, params, scopes, opts) do
    txn_id = random_token("txn")

    transaction = %{
      "client_id" => client["client_id"],
      "client_name" => client["client_name"],
      "redirect_uri" => redirect_uri,
      "state" => Map.get(params, "state"),
      "scopes" => scopes,
      "code_challenge" => Map.get(params, "code_challenge"),
      "code_challenge_method" => Map.get(params, "code_challenge_method", "plain")
    }

    :ok =
      StateStore.put(transaction_store(http_context, opts), transaction_key(txn_id), transaction)

    {:ok,
     join_url(
       http_context.base_url,
       consent_path(opts) <> "?txn_id=" <> URI.encode_www_form(txn_id)
     )}
  end

  defp get_authorization_transaction(http_context, txn_id) do
    case StateStore.get(transaction_store(http_context, %{}), transaction_key(txn_id)) do
      {:ok, transaction} ->
        {:ok, transaction}

      {:error, :not_found} ->
        oauth_error(:invalid_request, "authorization transaction is invalid or expired")
    end
  end

  defp ensure_transaction_csrf(http_context, txn_id, transaction) do
    csrf_token = Map.get(transaction, "csrf_token") || random_token("csrf")
    updated_transaction = Map.put(transaction, "csrf_token", csrf_token)

    :ok =
      StateStore.put(
        transaction_store(http_context, %{}),
        transaction_key(txn_id),
        updated_transaction
      )

    {:ok, csrf_token, updated_transaction}
  end

  defp delete_authorization_transaction(http_context, txn_id) do
    :ok = StateStore.delete(transaction_store(http_context, %{}), transaction_key(txn_id))
    :ok
  end

  defp validate_consent_csrf(conn, txn_id, csrf_token, transaction) do
    with {:ok, {cookie_txn_id, cookie_csrf}} <-
           decode_consent_cookie(conn.cookies[@consent_csrf_cookie]),
         true <- cookie_txn_id == txn_id,
         true <- cookie_csrf == csrf_token,
         true <- Map.get(transaction, "csrf_token") == csrf_token do
      :ok
    else
      _ ->
        {:oauth_error, 403,
         %{"error" => "invalid_request", "error_description" => "consent csrf validation failed"},
         []}
    end
  end

  defp consent_redirect(conn, http_context, opts, "approve", txn_id, transaction) do
    params = %{
      "state" => Map.get(transaction, "state"),
      "code_challenge" => Map.get(transaction, "code_challenge"),
      "code_challenge_method" => Map.get(transaction, "code_challenge_method", "plain")
    }

    if oauth_proxy_enabled?(opts) do
      with {:ok, %{url: url, session_params: session_params}} <-
             AssentFlow.authorize_url(
               upstream_oauth_flow(opts, http_context),
               upstream_authorization_params(transaction)
             ),
           {:ok, upstream_state} <- upstream_state(session_params),
           :ok <-
             store_upstream_authorization(
               http_context,
               opts,
               upstream_state,
               transaction,
               session_params
             ),
           :ok <- delete_authorization_transaction(http_context, txn_id) do
        {:ok, url, conn}
      end
    else
      with {:ok, code} <-
             store_authorization_code(
               http_context,
               %{"client_id" => transaction["client_id"]},
               transaction["redirect_uri"],
               params,
               transaction["scopes"],
               opts
             ),
           :ok <- delete_authorization_transaction(http_context, txn_id) do
        {:ok,
         build_redirect_uri(transaction["redirect_uri"], %{
           "code" => code,
           "state" => transaction["state"]
         }), conn}
      end
    end
  end

  defp consent_redirect(conn, http_context, _opts, "deny", txn_id, transaction) do
    conn =
      put_resp_cookie(conn, @denied_clients_cookie, transaction["client_id"] || "unknown",
        http_only: true,
        same_site: "Lax",
        secure: secure_cookie?(http_context),
        path: "/"
      )

    with :ok <- delete_authorization_transaction(http_context, txn_id) do
      {:ok,
       build_redirect_uri(transaction["redirect_uri"], %{
         "error" => "access_denied",
         "state" => transaction["state"]
       }), conn}
    end
  end

  defp consent_redirect(_conn, _http_context, _opts, _action, _txn_id, _transaction) do
    oauth_error(:invalid_request, "consent action is invalid")
  end

  defp clear_consent_cookie(conn, opts) do
    delete_resp_cookie(conn, @consent_csrf_cookie, path: consent_path(opts))
  end

  defp render_consent_html(transaction, txn_id, csrf_token, opts) do
    client_label =
      escape_html(transaction["client_name"] || transaction["client_id"] || "OAuth client")

    scopes = transaction["scopes"] |> normalize_scopes() |> Enum.join(", ")

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Authorize #{client_label}</title>
      </head>
      <body>
        <main>
          <h1>Authorize #{client_label}</h1>
          <p>This client is requesting access to: #{escape_html(scopes)}</p>
          <form method="post" action="#{escape_html(consent_path(opts))}">
            <input type="hidden" name="txn_id" value="#{escape_html(txn_id)}" />
            <input type="hidden" name="csrf_token" value="#{escape_html(csrf_token)}" />
            <button type="submit" name="action" value="approve">Approve</button>
            <button type="submit" name="action" value="deny">Deny</button>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp render_authorize_error_html(payload) do
    registration_endpoint = escape_html(payload["registration_endpoint"] || "")
    discovery_endpoint = escape_html(payload["authorization_server_metadata"] || "")
    server_name = escape_html(payload["server_name"] || "FastestMCP")
    server_icon_url = escape_html(payload["server_icon_url"] || "")

    error_description =
      escape_html(payload["error_description"] || "authorization request failed")

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Client Not Registered</title>
      </head>
      <body>
        <main>
          #{render_authorize_error_branding(server_name, server_icon_url)}
          <h1>Client Not Registered</h1>
          <p>#{error_description}</p>
          <p>To fix this, register the client first at <code>#{registration_endpoint}</code>.</p>
          <p>Discovery metadata is available at <code>#{discovery_endpoint}</code>.</p>
          <p>Close this browser window and clear authentication tokens before retrying.</p>
        </main>
      </body>
    </html>
    """
  end

  defp render_authorize_error_branding(server_name, ""), do: "<h2>" <> server_name <> "</h2>"

  defp render_authorize_error_branding(server_name, server_icon_url) do
    """
    <header>
      <img src="#{server_icon_url}" alt="#{server_name}" style="max-width:48px;max-height:48px;" />
      <h2>#{server_name}</h2>
    </header>
    """
  end

  defp decode_consent_cookie(nil), do: {:error, :missing_cookie}

  defp decode_consent_cookie(cookie) do
    with {:ok, decoded} <- Base.url_decode64(cookie, padding: false),
         [txn_id, csrf_token] <- String.split(decoded, ":", parts: 2),
         true <- txn_id != "",
         true <- csrf_token != "" do
      {:ok, {txn_id, csrf_token}}
    else
      _ -> {:error, :invalid_cookie}
    end
  end

  defp encode_consent_cookie(txn_id, csrf_token) do
    Base.url_encode64("#{txn_id}:#{csrf_token}", padding: false)
  end

  defp wants_html?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp secure_cookie?(http_context) do
    URI.parse(http_context.base_url).scheme == "https"
  end

  defp consent_enabled?(opts), do: opt(opts, :consent, false)
  defp consent_path(opts), do: normalize_path(opt(opts, :consent_path, "/consent"))
  defp enable_cimd?(opts), do: opt(opts, :enable_cimd, true)
  defp oauth_proxy_enabled?(opts), do: not is_nil(opt(opts, :upstream_oauth_flow))

  defp transaction_store(http_context, opts),
    do: opt(opts, :transaction_store) || Map.fetch!(http_context, :oauth_state_store)

  defp transaction_key(txn_id), do: "txn:" <> txn_id
  defp upstream_transaction_key(state), do: "upstream:" <> state

  defp maybe_fetch_cimd_client(http_context, opts, client_id) do
    if enable_cimd?(opts) and CIMD.is_client_id?(client_id) do
      case CIMD.fetch(client_id, cimd_fetch_options(opts)) do
        {:ok, document} ->
          {:ok, synthetic_cimd_client(client_id, document, opts)}

        {:error, _reason} ->
          unregistered_client_error(
            http_context,
            opts,
            client_id,
            "client #{client_id} is not registered and its client metadata document could not be resolved"
          )
      end
    else
      unregistered_client_error(
        http_context,
        opts,
        client_id,
        "client #{client_id} is not registered"
      )
    end
  end

  defp unregistered_client_error(http_context, opts, _client_id, description) do
    metadata_url = authorization_server_metadata_url(http_context, opts)
    register_url = join_url(http_context.base_url, registration_path(opts))
    state = opt(opts, :authorize_state)
    {server_name, server_icon_url} = authorize_error_branding(http_context)

    {:oauth_error, 400,
     %{
       "error" => "invalid_request",
       "error_description" => enhanced_unregistered_client_description(description),
       "state" => state,
       "registration_endpoint" => register_url,
       "authorization_server_metadata" => metadata_url,
       "server_name" => server_name,
       "server_icon_url" => server_icon_url
     }, [{"link", ~s(<#{register_url}>; rel="http://oauth.net/core/2.1/#registration")}]}
  end

  defp authorize_error_branding(http_context) do
    metadata = Map.get(http_context, :server_metadata, %{})

    {
      map_value(metadata, :display_name) || map_value(metadata, :name) ||
        Map.get(http_context, :server_name) || "FastestMCP",
      map_value(metadata, :icon_url) || first_icon_src(map_value(metadata, :icons))
    }
  end

  defp enhanced_unregistered_client_description(description) do
    description <>
      ". MCP clients should automatically re-register by sending a POST request to the registration_endpoint and retry authorization. If this persists, clear cached authentication tokens and reconnect."
  end

  defp first_icon_src(icons) when is_list(icons) do
    icons
    |> Enum.find_value(fn icon -> map_value(icon, :src) end)
  end

  defp first_icon_src(_icons), do: nil

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp synthetic_cimd_client(client_id, document, opts) do
    %{
      "client_id" => client_id,
      "client_secret" => nil,
      "redirect_uris" => nil,
      "grant_types" => List.wrap(Map.get(document, "grant_types", ["authorization_code"])),
      "response_types" => List.wrap(Map.get(document, "response_types", ["code"])),
      "token_endpoint_auth_method" => Map.get(document, "token_endpoint_auth_method", "none"),
      "allowed_redirect_uri_patterns" => opt(opts, :allowed_client_redirect_uris),
      "scope" => Map.get(document, "scope") || default_scope_string(opts),
      "client_name" => Map.get(document, "client_name"),
      "cimd_document" => document,
      "cimd_fetched_at" => System.os_time(:millisecond)
    }
  end

  defp cimd_fetch_options(opts) do
    []
    |> maybe_keyword_put(:cimd_fetcher, opt(opts, :cimd_fetcher))
    |> maybe_keyword_put(:cimd_timeout_ms, opt(opts, :cimd_timeout_ms))
    |> maybe_keyword_put(:cimd_overall_timeout_ms, opt(opts, :cimd_overall_timeout_ms))
    |> maybe_keyword_put(:cimd_max_size_bytes, opt(opts, :cimd_max_size_bytes))
    |> maybe_keyword_put(:cimd_resolver, opt(opts, :cimd_resolver))
    |> maybe_keyword_put(:cimd_requester, opt(opts, :cimd_requester))
  end

  defp private_key_jwt_options(opts) do
    []
    |> maybe_keyword_put(:jwks_fetcher, opt(opts, :jwks_fetcher))
    |> maybe_keyword_put(:jwks_timeout_ms, opt(opts, :jwks_timeout_ms))
    |> maybe_keyword_put(:jwks_cache_ttl_ms, opt(opts, :jwks_cache_ttl_ms))
    |> maybe_keyword_put(:ssrf_safe, opt(opts, :ssrf_safe))
    |> maybe_keyword_put(:ssrf_resolver, opt(opts, :ssrf_resolver))
    |> maybe_keyword_put(:ssrf_requester, opt(opts, :ssrf_requester))
    |> maybe_keyword_put(:ssrf_max_size_bytes, opt(opts, :ssrf_max_size_bytes))
    |> maybe_keyword_put(:ssrf_overall_timeout_ms, opt(opts, :ssrf_overall_timeout_ms))
  end

  defp validate_cimd_proxy_redirect(client, redirect_uri) do
    case Map.get(client, "allowed_redirect_uri_patterns") do
      nil ->
        :ok

      allowed_patterns ->
        if RedirectURI.validate_redirect_uri(redirect_uri, allowed_patterns) do
          :ok
        else
          oauth_error(:invalid_request, "redirect_uri does not match allowed patterns")
        end
    end
  end

  defp escape_html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp fetch_runtime(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, :not_found} ->
        {:error, %Error{code: :internal_error, message: "server runtime is not available"}}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to fetch server runtime",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp upstream_oauth_flow(opts, http_context) do
    case opt(opts, :upstream_oauth_flow) do
      %AssentFlow{} = flow ->
        config =
          Keyword.put_new(
            flow.config,
            :redirect_uri,
            join_url(http_context.base_url, callback_path(opts))
          )

        %{flow | config: config}

      nil ->
        raise ArgumentError, "upstream_oauth_flow must be configured for oauth proxy mode"
    end
  end

  defp upstream_authorization_params(transaction) do
    []
    |> maybe_keyword_put(:scope, transaction["upstream_scope"])
  end

  defp upstream_state(session_params) do
    case Map.get(Map.new(session_params), "state") || Map.get(Map.new(session_params), :state) do
      state when is_binary(state) and state != "" -> {:ok, state}
      _ -> oauth_error(:invalid_request, "upstream oauth flow did not return state")
    end
  end

  defp store_upstream_authorization(http_context, opts, state, transaction, session_params) do
    StateStore.put(transaction_store(http_context, opts), upstream_transaction_key(state), %{
      "transaction" => transaction,
      "session_params" => Map.new(session_params)
    })
  end

  defp take_upstream_authorization(http_context, opts, state) do
    case StateStore.take(transaction_store(http_context, opts), upstream_transaction_key(state)) do
      {:ok, stored_context} ->
        {:ok, stored_context}

      {:error, :not_found} ->
        oauth_error(:invalid_grant, "upstream oauth state is invalid or expired")
    end
  end

  defp upstream_authorization_metadata(result) do
    token_response =
      normalize_map(get_nested(result, ["token"]) || get_nested(result, [:token]) || %{})

    auth =
      %{
        "upstream_access_token" => Map.get(token_response, "access_token"),
        "upstream_refresh_token" => Map.get(token_response, "refresh_token"),
        "upstream_id_token" => Map.get(token_response, "id_token"),
        "upstream_user" => get_nested(result, ["user"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "provider" => "oauth_proxy",
      "principal" => upstream_principal(result),
      "auth" => auth
    }
  end

  defp metadata_from_token_record(record) do
    %{}
    |> maybe_put_metadata("principal", Map.get(record, "principal"))
    |> maybe_put_metadata("provider", Map.get(record, "provider"))
    |> maybe_put_metadata("auth", Map.get(record, "auth"))
  end

  defp upstream_principal(result) do
    get_nested(result, ["user"]) || get_nested(result, [:user]) || %{}
  end

  defp get_nested(value, []), do: value

  defp get_nested(map, [key | rest]) when is_map(map) do
    next =
      Map.get(map, key) ||
        if is_atom(key),
          do: Map.get(map, Atom.to_string(key)),
          else: Map.get(map, String.to_atom(key))

    get_nested(next, rest)
  rescue
    ArgumentError -> get_nested(Map.get(map, key), rest)
  end

  defp get_nested(_value, _path), do: nil

  defp normalize_provider(provider) when is_binary(provider), do: String.to_atom(provider)
  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(_provider), do: :local_oauth

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp service_documentation_url(opts) do
    case opt(opts, :service_documentation_url) do
      nil -> nil
      url -> normalize_url(url)
    end
  end

  defp authorization_server_metadata_url(http_context, opts) do
    join_absolute_url(
      authorization_server_issuer(http_context, opts),
      authorization_server_metadata_path(http_context, opts)
    )
  end

  defp issuer_path(http_context, opts) do
    http_context
    |> authorization_server_issuer(opts)
    |> URI.parse()
    |> Map.get(:path)
    |> normalize_optional_path()
  end

  defp normalize_optional_path(nil), do: ""
  defp normalize_optional_path(""), do: ""
  defp normalize_optional_path("/"), do: ""
  defp normalize_optional_path(path), do: normalize_path(path)

  defp normalize_url(url) do
    url
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp maybe_keyword_put(keyword, _key, value) when value in [nil, ""], do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp with_authorize_state(opts, nil), do: opts

  defp with_authorize_state(opts, state) when is_list(opts),
    do: Keyword.put(opts, :authorize_state, state)

  defp with_authorize_state(opts, state) when is_map(opts),
    do: Map.put(opts, :authorize_state, state)

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
