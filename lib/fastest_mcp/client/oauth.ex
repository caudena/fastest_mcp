defmodule FastestMCP.Client.OAuth do
  @moduledoc """
  MCP 2025-11-25 OAuth coordinator for Streamable HTTP clients.

  The coordinator implements protected-resource and authorization-server
  discovery, PKCE S256, resource indicators, explicit client registration
  modes, refresh-token rotation, and scope step-up. Browser interaction remains
  behind `FastestMCP.Client.OAuth.AuthorizationHandler`.

  Start one coordinator per connected client. The default token store is
  process-local and non-durable:

      {:ok, oauth} =
        FastestMCP.Client.OAuth.start_link(
          redirect_uri: "http://127.0.0.1:8765/callback",
          registration: {:pre_registered, [client_id: "my-client"]},
          authorization_handler: MyApp.OAuthBrowser
        )

  The connected client normally invokes this module automatically after a 401
  response. Direct calls are useful to hosts that want to authorize eagerly.
  """

  use GenServer

  alias FastestMCP.Client.OAuth.AuthorizationHandler
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Client.OAuth.TokenStore.Memory
  alias FastestMCP.HTTP
  alias FastestMCP.MIME

  @default_timeout_ms 5_000
  @default_max_body_bytes 1_048_576
  @refresh_skew_ms 30_000

  @type registration ::
          {:pre_registered, keyword() | map()}
          | {:client_metadata_document, String.t()}
          | {:dynamic, keyword() | map()}

  @type option ::
          {:redirect_uri, String.t()}
          | {:registration, registration()}
          | {:authorization_handler, module() | (AuthorizationHandler.Request.t() -> term())}
          | {:token_store, {module(), term()}}
          | {:authorization_server, String.t()}
          | {:scopes, [String.t()]}
          | {:requester, (atom(), String.t(), keyword() -> term())}
          | {:timeout_ms, pos_integer()}
          | {:max_body_bytes, pos_integer()}

  @doc "Starts an OAuth coordinator from explicit client options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns a cached/refreshable Bearer header, or `:none` before authorization."
  @spec authorization_header(GenServer.server(), String.t()) ::
          {:ok, String.t()} | :none | {:error, Error.t()}
  def authorization_header(server, resource) when is_binary(resource) do
    GenServer.call(server, {:authorization_header, resource}, :infinity)
  end

  @doc "Handles a protected-resource challenge and returns a Bearer header."
  @spec handle_unauthorized(GenServer.server(), String.t(), list() | map(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def handle_unauthorized(server, resource, response_headers, opts \\ [])
      when is_binary(resource) and is_list(opts) do
    GenServer.call(
      server,
      {:handle_unauthorized, resource, response_headers, opts},
      :infinity
    )
  end

  @doc "Performs authorization without requiring a preceding 401 response."
  @spec authorize(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def authorize(server, resource, opts \\ []) when is_binary(resource) and is_list(opts) do
    GenServer.call(server, {:authorize, resource, opts}, :infinity)
  end

  @doc "Deletes cached credentials for one resource."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(server, resource) when is_binary(resource) do
    GenServer.call(server, {:clear, resource})
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- normalize_config(opts),
         {:ok, token_store, owns_store?} <- initialize_token_store(config.token_store) do
      {:ok,
       %{
         config: config,
         token_store: token_store,
         owns_store?: owns_store?,
         resources: %{}
       }}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def terminate(_reason, %{owns_store?: true, token_store: {_module, pid}}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:authorization_header, raw_resource}, _from, state) do
    with {:ok, resource} <- canonical_resource(raw_resource) do
      case Map.get(state.resources, resource) do
        nil ->
          {:reply, :none, state}

        context ->
          case stored_token(state, context) do
            nil ->
              {:reply, :none, state}

            token ->
              cond do
                token_current?(token) ->
                  {:reply, {:ok, bearer_header(token)}, state}

                is_binary(token["refresh_token"]) ->
                  case refresh_token(state, context, token) do
                    {:ok, refreshed, next_state} ->
                      {:reply, {:ok, bearer_header(refreshed)}, next_state}

                    {:error, %Error{} = error, next_state} ->
                      {:reply, {:error, error}, next_state}
                  end

                true ->
                  next_state = delete_stored_token(state, context)
                  {:reply, :none, next_state}
              end
          end
      end
    else
      {:error, reason} ->
        {:reply, {:error, oauth_error(:configuration, reason)}, state}
    end
  end

  def handle_call({:handle_unauthorized, raw_resource, headers, opts}, _from, state) do
    attempt = Keyword.get(opts, :attempt, 1)

    with {:ok, resource} <- canonical_resource(raw_resource),
         {:ok, challenge} <- parse_bearer_challenge(headers) do
      context = Map.get(state.resources, resource)
      token = context && stored_token(state, context)

      cond do
        attempt == 1 and challenge.error != "insufficient_scope" and
          is_map(token) and is_binary(token["refresh_token"]) ->
          case refresh_token(state, context, token) do
            {:ok, refreshed, next_state} ->
              {:reply, {:ok, bearer_header(refreshed)}, next_state}

            {:error, _refresh_error, next_state} ->
              authorize_and_reply(next_state, resource, challenge, opts)
          end

        true ->
          authorize_and_reply(state, resource, challenge, opts)
      end
    else
      {:error, reason} ->
        {:reply, {:error, oauth_error(:protected_resource_discovery, reason)}, state}
    end
  end

  def handle_call({:authorize, raw_resource, opts}, _from, state) do
    with {:ok, resource} <- canonical_resource(raw_resource) do
      challenge = %{
        resource_metadata: Keyword.get(opts, :resource_metadata),
        scopes: normalize_scopes(Keyword.get(opts, :scopes, [])),
        error: nil
      }

      authorize_and_reply(state, resource, challenge, opts)
    else
      {:error, reason} ->
        {:reply, {:error, oauth_error(:configuration, reason)}, state}
    end
  end

  def handle_call({:clear, raw_resource}, _from, state) do
    next_state =
      case canonical_resource(raw_resource) do
        {:ok, resource} ->
          case Map.pop(state.resources, resource) do
            {nil, resources} ->
              %{state | resources: resources}

            {context, resources} ->
              state
              |> delete_stored_token(context)
              |> Map.put(:resources, resources)
          end

        {:error, _reason} ->
          state
      end

    {:reply, :ok, next_state}
  end

  defp authorize_and_reply(state, resource, challenge, opts) do
    case perform_authorization(state, resource, challenge, opts) do
      {:ok, token, next_state} -> {:reply, {:ok, bearer_header(token)}, next_state}
      {:error, %Error{} = error, next_state} -> {:reply, {:error, error}, next_state}
    end
  end

  defp perform_authorization(state, resource, challenge, opts) do
    with {:ok, protected_resource} <- discover_protected_resource(state, resource, challenge),
         {:ok, authorization_server} <-
           select_authorization_server(protected_resource, state.config.authorization_server),
         {:ok, server_metadata} <- discover_authorization_server(state, authorization_server),
         {:ok, client} <- resolve_client_registration(state, server_metadata),
         {:ok, verifier, authorization_request} <-
           build_authorization_request(
             state,
             resource,
             protected_resource,
             server_metadata,
             client,
             challenge,
             opts
           ),
         {:ok, code} <- authorize_with_host(state, authorization_request),
         {:ok, token} <-
           exchange_code(
             state,
             server_metadata,
             client,
             resource,
             code,
             verifier,
             authorization_request.scopes
           ) do
      context = %{
        resource: resource,
        protected_resource: protected_resource,
        authorization_server: authorization_server,
        server_metadata: server_metadata,
        client: client,
        token_key: {resource, authorization_server, client.client_id}
      }

      next_state =
        state
        |> put_stored_token(context, token)
        |> put_in([:resources, resource], context)

      {:ok, token, next_state}
    else
      {:error, %Error{} = error} -> {:error, error, state}
      {:error, stage, reason} -> {:error, oauth_error(stage, reason), state}
      {:error, reason} -> {:error, oauth_error(:authorization, reason), state}
    end
  end

  defp discover_protected_resource(state, resource, challenge) do
    candidates =
      case challenge.resource_metadata do
        value when is_binary(value) and value != "" -> [value]
        _other -> protected_resource_candidates(resource)
      end

    candidates
    |> Enum.reduce_while({:error, :metadata_not_found}, fn candidate, _last_error ->
      case fetch_json_document(
             state,
             candidate,
             :protected_resource_discovery,
             {:protected_resource, resource}
           ) do
        {:ok, document} ->
          case validate_protected_resource(document, resource) do
            {:ok, validated} -> {:halt, {:ok, validated}}
            {:error, reason} -> {:halt, {:error, :protected_resource_discovery, reason}}
          end

        {:error, %Error{reason: {:http_status, 404}}} ->
          {:cont, {:error, :metadata_not_found}}

        {:error, %Error{} = error} ->
          if is_binary(challenge.resource_metadata) do
            {:halt, {:error, error}}
          else
            {:cont, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, document} -> {:ok, document}
      {:error, %Error{} = error} -> {:error, error}
      {:error, stage, reason} -> {:error, stage, reason}
      {:error, reason} -> {:error, :protected_resource_discovery, reason}
    end
  end

  defp validate_protected_resource(document, expected_resource) when is_map(document) do
    with resource when is_binary(resource) <- document["resource"],
         {:ok, canonical} <- canonical_resource(resource),
         true <- resource_matches_request?(canonical, expected_resource),
         servers when is_list(servers) and servers != [] <- document["authorization_servers"],
         {:ok, servers} <- validate_https_urls(servers) do
      {:ok,
       document
       |> Map.put("resource", canonical)
       |> Map.put("authorization_servers", servers)}
    else
      nil -> {:error, :resource_required}
      false -> {:error, :resource_mismatch}
      [] -> {:error, :authorization_servers_required}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_protected_resource_metadata}
    end
  end

  defp select_authorization_server(%{"authorization_servers" => servers}, nil),
    do: {:ok, hd(servers)}

  defp select_authorization_server(%{"authorization_servers" => servers}, selected) do
    with {:ok, canonical} <- canonical_https_url(selected),
         true <- canonical in servers do
      {:ok, canonical}
    else
      false -> {:error, :authorization_server_not_advertised}
      {:error, reason} -> {:error, reason}
    end
  end

  # A root protected-resource metadata document describes the whole origin.
  # Keep the requested MCP endpoint as the RFC 8707 resource indicator, but
  # accept the origin identifier returned by the root discovery fallback.
  # Non-root metadata remains exact so a sibling path cannot claim the request.
  defp resource_matches_request?(resource, expected_resource) do
    resource == expected_resource or root_resource_for_request?(resource, expected_resource)
  end

  defp root_resource_for_request?(resource, expected_resource) do
    resource_uri = URI.parse(resource)
    expected_uri = URI.parse(expected_resource)

    resource_uri.path in [nil, "", "/"] and
      {resource_uri.scheme, resource_uri.host, effective_port(resource_uri)} ==
        {expected_uri.scheme, expected_uri.host, effective_port(expected_uri)}
  end

  defp discover_authorization_server(state, issuer) do
    issuer
    |> authorization_server_metadata_candidates()
    |> Enum.reduce_while({:error, :metadata_not_found}, fn candidate, _last_error ->
      case fetch_json_document(state, candidate, :authorization_server_discovery, :https) do
        {:ok, document} ->
          case validate_authorization_server_metadata(document, issuer) do
            {:ok, validated} -> {:halt, {:ok, validated}}
            {:error, reason} -> {:halt, {:error, :authorization_server_discovery, reason}}
          end

        {:error, %Error{reason: {:http_status, 404}}} ->
          {:cont, {:error, :metadata_not_found}}

        {:error, %Error{} = error} ->
          {:cont, {:error, error}}
      end
    end)
    |> case do
      {:ok, metadata} -> {:ok, metadata}
      {:error, %Error{} = error} -> {:error, error}
      {:error, stage, reason} -> {:error, stage, reason}
      {:error, reason} -> {:error, :authorization_server_discovery, reason}
    end
  end

  defp validate_authorization_server_metadata(document, expected_issuer)
       when is_map(document) do
    with issuer when is_binary(issuer) <- document["issuer"],
         {:ok, issuer} <- canonical_https_url(issuer),
         true <- issuer == expected_issuer,
         {:ok, authorization_endpoint} <-
           canonical_https_url(document["authorization_endpoint"]),
         {:ok, token_endpoint} <- canonical_https_url(document["token_endpoint"]),
         methods when is_list(methods) <- document["code_challenge_methods_supported"],
         true <- "S256" in methods,
         :ok <- validate_optional_https_endpoint(document, "registration_endpoint") do
      {:ok,
       document
       |> Map.put("issuer", issuer)
       |> Map.put("authorization_endpoint", authorization_endpoint)
       |> Map.put("token_endpoint", token_endpoint)}
    else
      false -> {:error, :issuer_or_pkce_mismatch}
      nil -> {:error, :authorization_server_metadata_incomplete}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :pkce_s256_required}
    end
  end

  defp resolve_client_registration(state, server_metadata) do
    case state.config.registration do
      {:pre_registered, client} ->
        validate_registered_client(client)

      {:client_metadata_document, client_id} ->
        with true <- server_metadata["client_id_metadata_document_supported"] == true,
             {:ok, client_id} <- validate_client_metadata_url(client_id) do
          {:ok,
           %{
             client_id: client_id,
             client_secret: nil,
             token_endpoint_auth_method: "none"
           }}
        else
          false -> {:error, :client_registration, :client_metadata_document_unsupported}
          {:error, reason} -> {:error, :client_registration, reason}
        end

      {:dynamic, metadata} ->
        dynamically_register_client(state, server_metadata, metadata)
    end
  end

  defp dynamically_register_client(state, server_metadata, metadata) do
    case server_metadata["registration_endpoint"] do
      endpoint when is_binary(endpoint) ->
        payload =
          metadata
          |> stringify_keys()
          |> Map.put_new("client_name", "FastestMCP Client")
          |> Map.put_new("redirect_uris", [state.config.redirect_uri])
          |> Map.put_new("grant_types", ["authorization_code", "refresh_token"])
          |> Map.put_new("response_types", ["code"])
          |> Map.put_new("token_endpoint_auth_method", "none")

        with {:ok, status, _headers, body} <-
               oauth_request(state, :post, endpoint, json: payload),
             :ok <- ensure_success_status(status),
             {:ok, document} <- decode_json_object(body),
             {:ok, client} <- validate_registered_client(document) do
          {:ok, client}
        else
          {:error, {:http_status, status}} ->
            {:error, :client_registration, {:http_status, status}}

          {:error, :client_registration, reason} ->
            {:error, :client_registration, reason}

          {:error, reason} ->
            {:error, :client_registration, sanitize_reason(reason)}
        end

      _other ->
        {:error, :client_registration, :dynamic_registration_unsupported}
    end
  end

  defp validate_registered_client(client) when is_list(client),
    do: client |> Map.new() |> validate_registered_client()

  defp validate_registered_client(client) when is_map(client) do
    client = stringify_keys(client)
    client_id = client["client_id"]
    method = client["token_endpoint_auth_method"] || "none"
    secret = client["client_secret"]

    cond do
      not is_binary(client_id) or client_id == "" ->
        {:error, :client_registration, :client_id_required}

      method not in ["none", "client_secret_basic", "client_secret_post"] ->
        {:error, :client_registration, :unsupported_token_endpoint_auth_method}

      method != "none" and (not is_binary(secret) or secret == "") ->
        {:error, :client_registration, :client_secret_required}

      true ->
        {:ok,
         %{
           client_id: client_id,
           client_secret: secret,
           token_endpoint_auth_method: method
         }}
    end
  end

  defp validate_registered_client(_client),
    do: {:error, :client_registration, :invalid_client_registration}

  defp build_authorization_request(
         state,
         resource,
         protected_resource,
         server_metadata,
         client,
         challenge,
         opts
       ) do
    verifier = random_url_token(64)
    state_token = random_url_token(32)
    challenge_value = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    scopes =
      authorization_scopes(
        state,
        resource,
        protected_resource,
        challenge.scopes,
        Keyword.get(opts, :scopes, [])
      )

    query =
      [
        {"response_type", "code"},
        {"client_id", client.client_id},
        {"redirect_uri", state.config.redirect_uri},
        {"code_challenge", challenge_value},
        {"code_challenge_method", "S256"},
        {"resource", resource},
        {"state", state_token}
      ]
      |> maybe_append_scope(scopes)

    authorization_url = append_query(server_metadata["authorization_endpoint"], query)

    {:ok, verifier,
     %{
       authorization_url: authorization_url,
       redirect_uri: state.config.redirect_uri,
       resource: resource,
       scopes: scopes,
       state: state_token
     }}
  end

  defp authorization_scopes(state, resource, protected_resource, challenge_scopes, extra_scopes) do
    existing_scopes =
      case Map.get(state.resources, resource) do
        nil -> []
        context -> (stored_token(state, context) || %{})["scope"] || []
      end

    challenge_scopes = normalize_scopes(challenge_scopes)

    base =
      cond do
        state.config.scopes != [] -> state.config.scopes
        challenge_scopes != [] -> []
        true -> normalize_scopes(protected_resource["scopes_supported"] || [])
      end

    [base, challenge_scopes, existing_scopes, extra_scopes]
    |> Enum.flat_map(&normalize_scopes/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp authorize_with_host(state, request) do
    host_request = %AuthorizationHandler.Request{
      authorization_url: request.authorization_url,
      redirect_uri: request.redirect_uri,
      resource: request.resource,
      scopes: request.scopes
    }

    response =
      case state.config.authorization_handler do
        handler when is_function(handler, 1) -> handler.(host_request)
        module when is_atom(module) -> module.authorize(host_request)
      end

    validate_authorization_response(response, request)
  rescue
    _error -> {:error, :authorization, :authorization_handler_failed}
  catch
    _kind, _reason -> {:error, :authorization, :authorization_handler_failed}
  end

  defp validate_authorization_response({:ok, redirect}, request) when is_binary(redirect) do
    with {:ok, expected} <- parse_redirect_uri(request.redirect_uri),
         {:ok, actual} <- parse_redirect_uri(redirect),
         true <- same_redirect_endpoint?(expected, actual),
         query <- URI.decode_query(actual.query || ""),
         :ok <- reject_authorization_error(query),
         true <- secure_compare(query["state"], request.state),
         code when is_binary(code) and code != "" <- query["code"] do
      {:ok, code}
    else
      false -> {:error, :authorization, :state_or_redirect_mismatch}
      nil -> {:error, :authorization, :authorization_code_required}
      {:error, reason} -> {:error, :authorization, reason}
      _other -> {:error, :authorization, :invalid_authorization_redirect}
    end
  end

  defp validate_authorization_response({:ok, response}, request) when is_map(response) do
    response = stringify_keys(response)

    with {:ok, redirect_uri} <-
           fetch_authorization_value(
             response,
             "redirect_uri",
             :authorization_redirect_required
           ),
         {:ok, expected} <- parse_redirect_uri(request.redirect_uri),
         {:ok, actual} <- parse_redirect_uri(redirect_uri),
         :ok <- validate_redirect_endpoint(expected, actual),
         :ok <- reject_authorization_error(response),
         :ok <- validate_authorization_state(response["state"], request.state),
         {:ok, code} <-
           fetch_authorization_value(response, "code", :authorization_code_required) do
      {:ok, code}
    else
      {:error, reason} -> {:error, :authorization, reason}
    end
  end

  defp validate_authorization_response({:error, _reason}, _request),
    do: {:error, :authorization, :authorization_declined}

  defp validate_authorization_response(_response, _request),
    do: {:error, :authorization, :invalid_authorization_response}

  defp fetch_authorization_value(response, key, missing_reason) do
    case response[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, missing_reason}
    end
  end

  defp validate_redirect_endpoint(expected, actual) do
    if same_redirect_endpoint?(expected, actual),
      do: :ok,
      else: {:error, :state_or_redirect_mismatch}
  end

  defp validate_authorization_state(actual, expected) do
    if secure_compare(actual, expected), do: :ok, else: {:error, :state_mismatch}
  end

  defp exchange_code(state, metadata, client, resource, code, verifier, scopes) do
    form =
      [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"redirect_uri", state.config.redirect_uri},
        {"client_id", client.client_id},
        {"code_verifier", verifier},
        {"resource", resource}
      ]
      |> apply_client_auth_form(client)

    headers = client_auth_headers(client)

    with {:ok, status, _headers, body} <-
           oauth_request(state, :post, metadata["token_endpoint"], form: form, headers: headers),
         :ok <- ensure_success_status(status),
         {:ok, token} <- decode_token_response(body, scopes, nil) do
      {:ok, token}
    else
      {:error, {:http_status, status}} -> {:error, :token_exchange, {:http_status, status}}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp refresh_token(state, context, old_token) do
    client = context.client

    form =
      [
        {"grant_type", "refresh_token"},
        {"refresh_token", old_token["refresh_token"]},
        {"client_id", client.client_id},
        {"resource", context.resource}
      ]
      |> maybe_append_scope(old_token["scope"] || [])
      |> apply_client_auth_form(client)

    result =
      with {:ok, status, _headers, body} <-
             oauth_request(
               state,
               :post,
               context.server_metadata["token_endpoint"],
               form: form,
               headers: client_auth_headers(client)
             ),
           :ok <- ensure_success_status(status),
           {:ok, token} <-
             decode_token_response(body, old_token["scope"] || [], old_token["refresh_token"]) do
        next_state = put_stored_token(state, context, token)
        {:ok, token, next_state}
      else
        {:error, {:http_status, status}} ->
          {:error, oauth_error(:token_refresh, {:http_status, status})}

        {:error, reason} ->
          {:error, oauth_error(:token_refresh, sanitize_reason(reason))}
      end

    case result do
      {:ok, token, next_state} -> {:ok, token, next_state}
      {:error, error} -> {:error, error, delete_stored_token(state, context)}
    end
  end

  defp decode_token_response(body, requested_scopes, previous_refresh_token) do
    with {:ok, document} <- decode_json_object(body),
         access_token when is_binary(access_token) and access_token != "" <-
           document["access_token"],
         token_type when is_binary(token_type) <- document["token_type"],
         true <- String.downcase(token_type) == "bearer",
         {:ok, expires_at_ms} <- normalize_expiry(document["expires_in"]) do
      refresh_token = document["refresh_token"] || previous_refresh_token
      scope = normalize_scopes(document["scope"] || requested_scopes)

      {:ok,
       %{
         "access_token" => access_token,
         "token_type" => "Bearer",
         "refresh_token" => refresh_token,
         "scope" => scope,
         "expires_at_ms" => expires_at_ms
       }}
    else
      false -> {:error, :invalid_token_type}
      nil -> {:error, :invalid_token_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_token_response}
    end
  end

  defp fetch_json_document(state, url, stage, url_policy) do
    with {:ok, canonical_url} <- canonical_document_url(url, url_policy),
         {:ok, status, headers, body} <- oauth_request(state, :get, canonical_url),
         :ok <- ensure_exact_status(status, 200),
         :ok <- validate_json_content_type(headers),
         {:ok, document} <- decode_json_object(body) do
      {:ok, document}
    else
      {:error, {:http_status, status}} -> {:error, oauth_error(stage, {:http_status, status})}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, oauth_error(stage, sanitize_reason(reason))}
    end
  end

  defp oauth_request(state, method, url, opts \\ []) do
    request_opts =
      opts
      |> Keyword.put(:timeout_ms, state.config.timeout_ms)
      |> maybe_put_requester(state.config.requester)

    result =
      if state.config.requester do
        HTTP.request(method, url, request_opts)
      else
        HTTP.bounded_request(method, url, state.config.max_body_bytes, request_opts)
      end

    case result do
      {:ok, status, headers, body} when is_binary(body) ->
        if byte_size(body) <= state.config.max_body_bytes do
          {:ok, status, headers, body}
        else
          {:error, :response_too_large}
        end

      other ->
        other
    end
  end

  defp normalize_config(opts) do
    with {:ok, redirect_uri} <- validate_redirect_uri(Keyword.get(opts, :redirect_uri)),
         {:ok, registration} <- normalize_registration(Keyword.get(opts, :registration)),
         {:ok, authorization_handler} <-
           validate_authorization_handler(Keyword.get(opts, :authorization_handler)),
         {:ok, authorization_server} <-
           validate_optional_authorization_server(Keyword.get(opts, :authorization_server)),
         {:ok, scopes} <- validate_scope_list(Keyword.get(opts, :scopes, [])),
         {:ok, timeout_ms} <-
           positive_integer(Keyword.get(opts, :timeout_ms, @default_timeout_ms)),
         {:ok, max_body_bytes} <-
           positive_integer(Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)),
         :ok <- validate_requester(Keyword.get(opts, :requester)) do
      {:ok,
       %{
         redirect_uri: redirect_uri,
         registration: registration,
         authorization_handler: authorization_handler,
         authorization_server: authorization_server,
         scopes: scopes,
         requester: Keyword.get(opts, :requester),
         token_store: Keyword.get(opts, :token_store),
         timeout_ms: timeout_ms,
         max_body_bytes: max_body_bytes
       }}
    else
      {:error, reason} -> {:error, oauth_error(:configuration, reason)}
    end
  end

  defp normalize_registration({:pre_registered, client}) when is_list(client) or is_map(client),
    do: {:ok, {:pre_registered, client}}

  defp normalize_registration({:client_metadata_document, url}) when is_binary(url),
    do: {:ok, {:client_metadata_document, url}}

  defp normalize_registration({:dynamic, metadata}) when is_list(metadata) or is_map(metadata),
    do: {:ok, {:dynamic, Map.new(metadata)}}

  defp normalize_registration(_registration), do: {:error, :registration_required}

  defp validate_authorization_handler(handler) when is_function(handler, 1), do: {:ok, handler}

  defp validate_authorization_handler(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :authorize, 1) do
      {:ok, module}
    else
      {:error, :invalid_authorization_handler}
    end
  end

  defp validate_authorization_handler(_handler), do: {:error, :authorization_handler_required}

  defp validate_optional_authorization_server(nil), do: {:ok, nil}
  defp validate_optional_authorization_server(url), do: canonical_https_url(url)

  defp validate_requester(nil), do: :ok
  defp validate_requester(requester) when is_function(requester, 3), do: :ok
  defp validate_requester(_requester), do: {:error, :invalid_requester}

  defp initialize_token_store(nil) do
    case Memory.start_link() do
      {:ok, pid} -> {:ok, {Memory, pid}, true}
      {:error, reason} -> {:error, oauth_error(:configuration, sanitize_reason(reason))}
    end
  end

  defp initialize_token_store({module, store_ref}) when is_atom(module) do
    required = [get: 2, put: 3, delete: 2]

    if Code.ensure_loaded?(module) and
         Enum.all?(required, fn {name, arity} -> function_exported?(module, name, arity) end) do
      {:ok, {module, store_ref}, false}
    else
      {:error, oauth_error(:configuration, :invalid_token_store)}
    end
  end

  defp initialize_token_store(_store),
    do: {:error, oauth_error(:configuration, :invalid_token_store)}

  defp stored_token(%{token_store: {module, store_ref}}, %{token_key: key}),
    do: module.get(store_ref, key)

  defp put_stored_token(%{token_store: {module, store_ref}} = state, context, token) do
    :ok = module.put(store_ref, context.token_key, token)
    state
  end

  defp delete_stored_token(%{token_store: {module, store_ref}} = state, context) do
    :ok = module.delete(store_ref, context.token_key)
    state
  end

  defp token_current?(%{"access_token" => token, "expires_at_ms" => nil})
       when is_binary(token),
       do: true

  defp token_current?(%{"access_token" => token, "expires_at_ms" => expires_at})
       when is_binary(token) and is_integer(expires_at) do
    expires_at > System.system_time(:millisecond) + @refresh_skew_ms
  end

  defp token_current?(_token), do: false

  defp bearer_header(%{"access_token" => token}), do: "Bearer " <> token

  defp protected_resource_candidates(resource) do
    uri = URI.parse(resource)
    authority = uri_authority(uri)
    path = uri.path || "/"
    path_candidate = "#{uri.scheme}://#{authority}/.well-known/oauth-protected-resource#{path}"
    root_candidate = "#{uri.scheme}://#{authority}/.well-known/oauth-protected-resource"
    Enum.uniq([path_candidate, root_candidate])
  end

  defp authorization_server_metadata_candidates(issuer) do
    uri = URI.parse(issuer)
    authority = uri_authority(uri)
    path = normalize_issuer_path(uri.path)

    if path == "" do
      [
        "#{uri.scheme}://#{authority}/.well-known/oauth-authorization-server",
        "#{uri.scheme}://#{authority}/.well-known/openid-configuration"
      ]
    else
      [
        "#{uri.scheme}://#{authority}/.well-known/oauth-authorization-server#{path}",
        "#{uri.scheme}://#{authority}/.well-known/openid-configuration#{path}",
        "#{uri.scheme}://#{authority}#{path}/.well-known/openid-configuration"
      ]
    end
  end

  defp normalize_issuer_path(nil), do: ""
  defp normalize_issuer_path("/"), do: ""
  defp normalize_issuer_path(path), do: String.trim_trailing(path, "/")

  defp validate_client_metadata_url(url) do
    with {:ok, canonical} <- canonical_https_url(url),
         %URI{path: path} <- URI.parse(canonical),
         true <- is_binary(path) and path not in ["", "/"] do
      {:ok, canonical}
    else
      false -> {:error, :client_metadata_path_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_redirect_uri(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

    cond do
      uri.userinfo || uri.fragment || not is_binary(uri.host) ->
        {:error, :invalid_redirect_uri}

      scheme == "https" ->
        {:ok, canonical_uri(%{uri | scheme: scheme})}

      scheme == "http" and localhost?(uri.host) ->
        {:ok, canonical_uri(%{uri | scheme: scheme})}

      true ->
        {:error, :secure_redirect_uri_required}
    end
  end

  defp validate_redirect_uri(_url), do: {:error, :redirect_uri_required}

  defp parse_redirect_uri(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        {:ok, %{uri | scheme: String.downcase(scheme), host: String.downcase(host)}}

      _other ->
        {:error, :invalid_redirect_uri}
    end
  end

  defp same_redirect_endpoint?(expected, actual) do
    {expected.scheme, expected.host, effective_port(expected), expected.path || ""} ==
      {actual.scheme, actual.host, effective_port(actual), actual.path || ""} and
      is_nil(actual.fragment)
  end

  defp canonical_resource(url) do
    with {:ok, canonical} <- canonical_https_or_loopback_url(url) do
      uri = URI.parse(canonical)

      if is_nil(uri.query) do
        {:ok, canonical_resource_uri(uri)}
      else
        {:error, :resource_query_forbidden}
      end
    end
  end

  defp canonical_https_url(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

    cond do
      not is_binary(uri.host) or uri.host == "" -> {:error, :host_required}
      uri.userinfo || uri.fragment -> {:error, :unsafe_url}
      scheme == "https" -> {:ok, canonical_uri(%{uri | scheme: scheme})}
      true -> {:error, :https_required}
    end
  end

  defp canonical_https_url(_url), do: {:error, :invalid_url}

  defp canonical_https_or_loopback_url(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

    cond do
      not is_binary(uri.host) or uri.host == "" ->
        {:error, :host_required}

      uri.userinfo || uri.fragment ->
        {:error, :unsafe_url}

      scheme == "https" ->
        {:ok, canonical_uri(%{uri | scheme: scheme})}

      scheme == "http" and localhost?(uri.host) ->
        {:ok, canonical_uri(%{uri | scheme: scheme})}

      true ->
        {:error, :https_or_loopback_required}
    end
  end

  defp canonical_https_or_loopback_url(_url), do: {:error, :invalid_url}

  defp canonical_document_url(url, :https), do: canonical_https_url(url)

  defp canonical_document_url(url, {:protected_resource, resource}) do
    with {:ok, canonical} <- canonical_https_or_loopback_url(url) do
      metadata_uri = URI.parse(canonical)

      if metadata_uri.scheme == "https" do
        {:ok, canonical}
      else
        with {:ok, canonical_resource} <- canonical_resource(resource),
             resource_uri <- URI.parse(canonical_resource),
             true <- same_origin?(metadata_uri, resource_uri) do
          {:ok, canonical}
        else
          false -> {:error, :https_required}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp canonical_uri(%URI{} = uri) do
    scheme = String.downcase(uri.scheme)
    host = String.downcase(uri.host)
    port = if default_port?(scheme, uri.port), do: nil, else: uri.port
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    URI.to_string(%{uri | scheme: scheme, host: host, port: port, path: path})
  end

  defp canonical_resource_uri(%URI{} = uri) do
    scheme = String.downcase(uri.scheme)
    host = String.downcase(uri.host)
    port = if default_port?(scheme, uri.port), do: nil, else: uri.port
    path = if uri.path in [nil, "", "/"], do: nil, else: uri.path
    URI.to_string(%{uri | scheme: scheme, host: host, port: port, path: path})
  end

  defp validate_https_urls(urls) do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
      case canonical_https_url(url) do
        {:ok, canonical} -> {:cont, {:ok, acc ++ [canonical]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_optional_https_endpoint(document, key) do
    case document[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        case canonical_https_url(value) do
          {:ok, _canonical} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_endpoint}
    end
  end

  defp validate_json_content_type(headers) do
    case response_header(headers, "content-type") do
      nil ->
        {:error, :json_content_type_required}

      value ->
        if MIME.json?(value),
          do: :ok,
          else: {:error, :invalid_json_content_type}
    end
  end

  defp decode_json_object(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _other} -> {:error, :json_object_required}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp parse_bearer_challenge(headers) do
    values = response_headers(headers, "www-authenticate")

    value =
      Enum.find(values, fn header ->
        String.match?(header, ~r/(?:^|,)\s*Bearer(?:\s|$)/i)
      end)

    if value do
      params = parse_auth_params(value)

      {:ok,
       %{
         resource_metadata: params["resource_metadata"],
         scopes: normalize_scopes(params["scope"] || []),
         error: params["error"]
       }}
    else
      {:ok, %{resource_metadata: nil, scopes: [], error: nil}}
    end
  end

  defp parse_auth_params(header) do
    ~r/([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:\\.|[^"])*)"|([^,\s]+))/
    |> Regex.scan(header)
    |> Enum.reduce(%{}, fn
      [_match, name, quoted, ""], acc ->
        Map.put(acc, String.downcase(name), unescape_quoted(quoted))

      [_match, name, "", token], acc ->
        Map.put(acc, String.downcase(name), token)

      [_match, name, quoted], acc ->
        Map.put(acc, String.downcase(name), unescape_quoted(quoted))
    end)
  end

  defp unescape_quoted(value),
    do: value |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  defp response_header(headers, name), do: List.first(response_headers(headers, name))

  defp response_headers(headers, name) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      if normalize_header_name(key) == name, do: List.wrap(value), else: []
    end)
    |> Enum.map(&to_string/1)
  end

  defp response_headers(headers, name) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} -> if normalize_header_name(key) == name, do: [to_string(value)], else: []
      _other -> []
    end)
  end

  defp response_headers(_headers, _name), do: []

  defp normalize_header_name(name), do: name |> to_string() |> String.downcase()

  defp reject_authorization_error(%{"error" => error}) when is_binary(error),
    do: {:error, :authorization_server_error}

  defp reject_authorization_error(_response), do: :ok

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right),
      do: Plug.Crypto.secure_compare(left, right),
      else: false
  end

  defp secure_compare(_left, _right), do: false

  defp apply_client_auth_form(form, %{token_endpoint_auth_method: "client_secret_post"} = client) do
    form ++ [{"client_secret", client.client_secret}]
  end

  defp apply_client_auth_form(form, _client), do: form

  defp client_auth_headers(%{token_endpoint_auth_method: "client_secret_basic"} = client) do
    username = URI.encode_www_form(client.client_id)
    password = URI.encode_www_form(client.client_secret)
    [{"authorization", "Basic " <> Base.encode64(username <> ":" <> password)}]
  end

  defp client_auth_headers(_client), do: []

  defp normalize_expiry(nil), do: {:ok, nil}

  defp normalize_expiry(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, System.system_time(:millisecond) + seconds * 1_000}

  defp normalize_expiry(_seconds), do: {:error, :invalid_token_expiry}

  defp normalize_scopes(scopes) when is_binary(scopes),
    do: String.split(scopes, ~r/\s+/, trim: true)

  defp normalize_scopes(scopes) when is_list(scopes),
    do: scopes |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))

  defp normalize_scopes(_scopes), do: []

  defp validate_scope_list(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &(is_binary(&1) and &1 != "" and not String.match?(&1, ~r/\s/))) do
      {:ok, Enum.uniq(scopes)}
    else
      {:error, :invalid_scopes}
    end
  end

  defp validate_scope_list(_scopes), do: {:error, :invalid_scopes}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :positive_integer_required}

  defp ensure_success_status(status) when status in 200..299, do: :ok
  defp ensure_success_status(status), do: {:error, {:http_status, status}}

  defp ensure_exact_status(status, status), do: :ok
  defp ensure_exact_status(status, _expected), do: {:error, {:http_status, status}}

  defp append_query(url, pairs) do
    uri = URI.parse(url)
    query = URI.encode_query(pairs, :rfc3986)
    existing = uri.query
    URI.to_string(%{uri | query: if(existing, do: existing <> "&" <> query, else: query)})
  end

  defp maybe_append_scope(pairs, []), do: pairs
  defp maybe_append_scope(pairs, scopes), do: pairs ++ [{"scope", Enum.join(scopes, " ")}]

  defp maybe_put_requester(opts, nil), do: opts
  defp maybe_put_requester(opts, requester), do: Keyword.put(opts, :requester, requester)

  defp random_url_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp localhost?(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp default_port?("https", port), do: port in [nil, 443]
  defp default_port?("http", port), do: port in [nil, 80]
  defp default_port?(_scheme, nil), do: true
  defp default_port?(_scheme, _port), do: false

  defp effective_port(%URI{scheme: "https", port: nil}), do: 443
  defp effective_port(%URI{scheme: "http", port: nil}), do: 80
  defp effective_port(%URI{port: port}), do: port

  defp same_origin?(left, right) do
    {left.scheme, String.downcase(left.host), effective_port(left)} ==
      {right.scheme, String.downcase(right.host), effective_port(right)}
  end

  defp uri_authority(%URI{host: host} = uri) do
    host =
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host

    if default_port?(uri.scheme, uri.port), do: host, else: "#{host}:#{uri.port}"
  end

  defp sanitize_reason({:http_status, status, _body}), do: {:http_status, status}
  defp sanitize_reason({:http_status, status}), do: {:http_status, status}
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(_reason), do: :request_failed

  defp oauth_error(stage, reason),
    do: Error.exception(stage: stage, reason: sanitize_reason(reason))
end
