defmodule FastestMCP.Client.OAuth do
  @moduledoc """
  MCP OAuth coordinator for HTTP clients.

  The coordinator implements protected-resource and authorization-server
  discovery, RFC 9207 issuer validation, PKCE S256, resource indicators,
  explicit client registration modes, refresh-token rotation, scope step-up,
  and the official client-credentials and enterprise-managed grant profiles.
  Browser interaction remains behind
  `FastestMCP.Client.OAuth.AuthorizationHandler`.

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
  alias FastestMCP.Client.OAuth.ClientAssertionProvider
  alias FastestMCP.Client.OAuth.EnterpriseManagedProvider
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Client.OAuth.TokenStore.Memory
  alias FastestMCP.HTTP
  alias FastestMCP.MIME

  @default_timeout_ms 5_000
  @default_max_body_bytes 1_048_576
  @refresh_skew_ms 30_000
  @jwt_bearer_grant "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @token_exchange_grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @jwt_client_assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @id_jag_token_type "urn:ietf:params:oauth:token-type:id-jag"
  @id_jag_grant_profile "urn:ietf:params:oauth:grant-profile:id-jag"

  @type registration ::
          {:pre_registered, keyword() | map()}
          | {:client_metadata_document, String.t()}
          | {:dynamic, keyword() | map()}

  @type assertion_provider ::
          module() | (ClientAssertionProvider.Request.t() -> ClientAssertionProvider.response())

  @type enterprise_provider ::
          module()
          | (EnterpriseManagedProvider.Request.t() -> EnterpriseManagedProvider.response())

  @type grant ::
          :authorization_code
          | {:authorization_code, keyword() | map()}
          | {:client_credentials, keyword() | map()}
          | {:enterprise_managed, keyword() | map()}

  @type option ::
          {:redirect_uri, String.t()}
          | {:grant, grant()}
          | {:registration, registration()}
          | {:authorization_handler, module() | (AuthorizationHandler.Request.t() -> term())}
          | {:token_store, {module(), term()}}
          | {:authorization_server, String.t()}
          | {:scopes, [String.t()]}
          | {:application_type, String.t()}
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
    credential_listener = Keyword.get(opts, :credential_listener)

    with :ok <- validate_credential_listener(credential_listener),
         {:ok, config} <- normalize_config(Keyword.delete(opts, :credential_listener)),
         {:ok, token_store, owns_store?} <- initialize_token_store(config.token_store) do
      {:ok,
       %{
         config: config,
         credential_listener: credential_listener,
         token_store: token_store,
         owns_store?: owns_store?,
         resources: %{},
         registrations: %{},
         credential_bindings: %{}
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
      previous_credential = stored_access_credential(state, resource)

      result =
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

                  reacquirable_grant?(context.grant) ->
                    next_state = delete_stored_token(state, context)

                    challenge = %{
                      resource_metadata: nil,
                      scopes: token["scope"] || [],
                      error: nil
                    }

                    case perform_authorization(
                           next_state,
                           resource,
                           challenge,
                           scopes: token["scope"] || []
                         ) do
                      {:ok, reacquired, final_state} ->
                        {:reply, {:ok, bearer_header(reacquired)}, final_state}

                      {:error, %Error{} = error, final_state} ->
                        {:reply, {:error, error}, final_state}
                    end

                  true ->
                    next_state = delete_stored_token(state, context)
                    {:reply, :none, next_state}
                end
            end
        end

      notify_credential_change(result, previous_credential, resource)
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
      previous_credential = token && token["access_token"]

      result =
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

      notify_credential_change(result, previous_credential, resource)
    else
      {:error, reason} ->
        {:reply, {:error, oauth_error(:protected_resource_discovery, reason)}, state}
    end
  end

  def handle_call({:authorize, raw_resource, opts}, _from, state) do
    with {:ok, resource} <- canonical_resource(raw_resource) do
      previous_credential = stored_access_credential(state, resource)

      challenge = %{
        resource_metadata: Keyword.get(opts, :resource_metadata),
        scopes: normalize_scopes(Keyword.get(opts, :scopes, [])),
        error: nil
      }

      state
      |> authorize_and_reply(resource, challenge, opts)
      |> notify_credential_change(previous_credential, resource)
    else
      {:error, reason} ->
        {:reply, {:error, oauth_error(:configuration, reason)}, state}
    end
  end

  def handle_call({:clear, raw_resource}, _from, state) do
    case canonical_resource(raw_resource) do
      {:ok, resource} ->
        previous_credential = stored_access_credential(state, resource)

        next_state =
          case Map.pop(state.resources, resource) do
            {nil, resources} ->
              %{state | resources: resources}

            {context, resources} ->
              state
              |> delete_stored_token(context)
              |> Map.put(:resources, resources)
          end

        {:reply, :ok, next_state}
        |> notify_credential_change(previous_credential, resource)

      {:error, _reason} ->
        {:reply, :ok, state}
    end
  end

  defp authorize_and_reply(state, resource, challenge, opts) do
    case perform_authorization(state, resource, challenge, opts) do
      {:ok, token, next_state} -> {:reply, {:ok, bearer_header(token)}, next_state}
      {:error, %Error{} = error, next_state} -> {:reply, {:error, error}, next_state}
    end
  end

  defp notify_credential_change(
         {:reply, _response, next_state} = reply,
         previous_credential,
         resource
       ) do
    current_credential = stored_access_credential(next_state, resource)

    if previous_credential != current_credential and is_pid(next_state.credential_listener) do
      send(next_state.credential_listener, :oauth_credentials_refreshed)
    end

    reply
  end

  defp stored_access_credential(state, resource) do
    with %{} = context <- Map.get(state.resources, resource),
         %{} = token <- stored_token(state, context),
         access_token when is_binary(access_token) <- token["access_token"] do
      access_token
    else
      _other -> nil
    end
  end

  defp perform_authorization(state, resource, challenge, opts) do
    with {:ok, protected_resource} <- discover_protected_resource(state, resource, challenge),
         {:ok, authorization_server} <-
           select_authorization_server(protected_resource, state.config.authorization_server),
         {:ok, server_metadata} <- discover_authorization_server(state, authorization_server) do
      perform_grant(
        state,
        resource,
        protected_resource,
        server_metadata,
        challenge,
        opts
      )
    else
      {:error, %Error{} = error} -> {:error, error, state}
      {:error, stage, reason} -> {:error, oauth_error(stage, reason), state}
      {:error, reason} -> {:error, oauth_error(:authorization, reason), state}
    end
  end

  defp perform_grant(
         state,
         resource,
         protected_resource,
         server_metadata,
         challenge,
         opts
       ) do
    case state.config.grant.type do
      :authorization_code ->
        perform_authorization_code(
          state,
          resource,
          protected_resource,
          server_metadata,
          challenge,
          opts
        )

      :client_credentials ->
        perform_client_credentials(
          state,
          resource,
          protected_resource,
          server_metadata,
          challenge,
          opts
        )

      :enterprise_managed ->
        perform_enterprise_managed(
          state,
          resource,
          protected_resource,
          server_metadata,
          challenge,
          opts
        )
    end
  end

  defp perform_authorization_code(
         state,
         resource,
         protected_resource,
         server_metadata,
         challenge,
         opts
       ) do
    case resolve_client_registration(state, server_metadata) do
      {:ok, client, registered_state} ->
        with {:ok, verifier, authorization_request} <-
               build_authorization_request(
                 registered_state,
                 resource,
                 protected_resource,
                 server_metadata,
                 client,
                 challenge,
                 opts
               ),
             {:ok, code} <- authorize_with_host(registered_state, authorization_request),
             {:ok, token} <-
               exchange_code(
                 registered_state,
                 server_metadata,
                 client,
                 resource,
                 code,
                 verifier,
                 authorization_request.scopes
               ) do
          store_grant_token(
            registered_state,
            resource,
            protected_resource,
            server_metadata,
            client,
            authorization_request.scopes,
            token
          )
        else
          {:error, stage, reason} -> {:error, oauth_error(stage, reason), registered_state}
        end

      {:error, stage, reason} ->
        {:error, oauth_error(stage, reason), state}
    end
  end

  defp perform_client_credentials(
         state,
         resource,
         protected_resource,
         server_metadata,
         challenge,
         opts
       ) do
    case resolve_client_registration(state, server_metadata) do
      {:ok, client, registered_state} ->
        scopes =
          authorization_scopes(
            registered_state,
            resource,
            protected_resource,
            challenge.scopes,
            Keyword.get(opts, :scopes, [])
          )

        case exchange_client_credentials(
               registered_state,
               server_metadata,
               client,
               resource,
               scopes
             ) do
          {:ok, token} ->
            store_grant_token(
              registered_state,
              resource,
              protected_resource,
              server_metadata,
              client,
              scopes,
              Map.put(token, "refresh_token", nil)
            )

          {:error, stage, reason} ->
            {:error, oauth_error(stage, reason), registered_state}
        end

      {:error, stage, reason} ->
        {:error, oauth_error(stage, reason), state}
    end
  end

  defp perform_enterprise_managed(
         state,
         resource,
         protected_resource,
         server_metadata,
         challenge,
         opts
       ) do
    case resolve_client_registration(state, server_metadata) do
      {:ok, client, registered_state} ->
        scopes =
          authorization_scopes(
            registered_state,
            resource,
            protected_resource,
            challenge.scopes,
            Keyword.get(opts, :scopes, [])
          )

        case exchange_enterprise_identity(
               registered_state,
               server_metadata,
               client,
               resource,
               scopes
             ) do
          {:ok, token} ->
            store_grant_token(
              registered_state,
              resource,
              protected_resource,
              server_metadata,
              client,
              scopes,
              Map.put(token, "refresh_token", nil)
            )

          {:error, stage, reason} ->
            {:error, oauth_error(stage, reason), registered_state}
        end

      {:error, stage, reason} ->
        {:error, oauth_error(stage, reason), state}
    end
  end

  defp store_grant_token(
         state,
         resource,
         protected_resource,
         server_metadata,
         client,
         scopes,
         token
       ) do
    issuer = server_metadata["issuer"]
    grant = state.config.grant.type

    context = %{
      resource: resource,
      protected_resource: protected_resource,
      authorization_server: issuer,
      server_metadata: server_metadata,
      client: client,
      grant: grant,
      scopes: scopes,
      token_key: token_key(resource, issuer, client.client_id, grant)
    }

    state =
      case Map.get(state.resources, resource) do
        %{token_key: previous_key} = previous when previous_key != context.token_key ->
          delete_stored_token(state, previous)

        _other ->
          state
      end

    next_state =
      state
      |> put_stored_token(context, token)
      |> put_in([:resources, resource], context)

    {:ok, token, next_state}
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
    with {:ok, selected} <- validate_exact_https_url(selected),
         true <- selected in servers do
      {:ok, selected}
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
          case validate_authorization_server_metadata(document, issuer, state.config.grant) do
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

  defp validate_authorization_server_metadata(document, expected_issuer, grant)
       when is_map(document) do
    recorded_issuer = document["issuer"]

    with issuer when is_binary(issuer) <- recorded_issuer,
         {:ok, issuer} <- validate_exact_https_url(issuer),
         true <- issuer == expected_issuer,
         {:ok, token_endpoint} <- validate_preserved_https_url(document["token_endpoint"]),
         :ok <- validate_optional_https_endpoint(document, "registration_endpoint"),
         :ok <-
           validate_optional_boolean(document, "authorization_response_iss_parameter_supported"),
         {:ok, grant_metadata} <- validate_grant_metadata(document, grant) do
      {:ok,
       document
       |> Map.put("issuer", issuer)
       |> Map.put("recorded_issuer", issuer)
       |> Map.put("token_endpoint", token_endpoint)
       |> Map.merge(grant_metadata)}
    else
      false -> {:error, :issuer_mismatch}
      nil -> {:error, :authorization_server_metadata_incomplete}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :authorization_server_metadata_incomplete}
    end
  end

  defp validate_grant_metadata(document, %{type: :authorization_code}) do
    with {:ok, authorization_endpoint} <-
           validate_preserved_https_url(document["authorization_endpoint"]),
         methods when is_list(methods) <- document["code_challenge_methods_supported"],
         true <- "S256" in methods do
      {:ok, %{"authorization_endpoint" => authorization_endpoint}}
    else
      false -> {:error, :pkce_s256_required}
      nil -> {:error, :authorization_server_metadata_incomplete}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :pkce_s256_required}
    end
  end

  defp validate_grant_metadata(document, %{type: :client_credentials, client: client}) do
    methods = document["token_endpoint_auth_methods_supported"]

    cond do
      not is_list(methods) ->
        {:error, :token_endpoint_auth_methods_required}

      client.token_endpoint_auth_method not in methods ->
        {:error, :token_endpoint_auth_method_not_supported}

      client.token_endpoint_auth_method == "private_key_jwt" and
          not valid_string_list?(document["token_endpoint_auth_signing_alg_values_supported"]) ->
        {:error, :token_endpoint_auth_signing_algorithms_required}

      true ->
        {:ok, %{}}
    end
  end

  defp validate_grant_metadata(document, %{type: :enterprise_managed}) do
    case document["authorization_grant_profiles_supported"] do
      nil ->
        {:ok, %{}}

      profiles when is_list(profiles) ->
        cond do
          @id_jag_grant_profile not in profiles ->
            {:error, :enterprise_managed_grant_not_supported}

          @jwt_bearer_grant not in List.wrap(document["grant_types_supported"]) ->
            {:error, :enterprise_managed_grant_metadata_inconsistent}

          true ->
            {:ok, %{}}
        end

      _other ->
        {:error, :invalid_authorization_server_metadata}
    end
  end

  defp resolve_client_registration(state, server_metadata) do
    case state.config.registration do
      {:pre_registered, client} ->
        with {:ok, client} <- validate_registered_client(client),
             {:ok, next_state} <- bind_pre_registered_client(state, client, server_metadata) do
          {:ok, client, next_state}
        end

      {:client_metadata_document, client_id} ->
        with true <- server_metadata["client_id_metadata_document_supported"] == true,
             {:ok, client_id} <- validate_client_metadata_url(client_id) do
          {:ok,
           %{
             client_id: client_id,
             client_secret: nil,
             token_endpoint_auth_method: "none",
             assertion_provider: nil,
             issuer: nil
           }, state}
        else
          false -> {:error, :client_registration, :client_metadata_document_unsupported}
          {:error, reason} -> {:error, :client_registration, reason}
        end

      {:dynamic, metadata} ->
        key = {server_metadata["issuer"], metadata}

        case Map.get(state.registrations, key) do
          nil ->
            case dynamically_register_client(state, server_metadata, metadata) do
              {:ok, client} ->
                {:ok, client, put_in(state, [:registrations, key], client)}

              {:error, stage, reason} ->
                {:error, stage, reason}
            end

          client ->
            {:ok, client, state}
        end
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
          |> Map.put_new("application_type", state.config.application_type)

        with :ok <- validate_application_type(payload["application_type"]),
             {:ok, status, _headers, body} <-
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
    assertion_provider = client["assertion_provider"]

    cond do
      not is_binary(client_id) or client_id == "" ->
        {:error, :client_registration, :client_id_required}

      method not in ["none", "client_secret_basic", "client_secret_post", "private_key_jwt"] ->
        {:error, :client_registration, :unsupported_token_endpoint_auth_method}

      method in ["client_secret_basic", "client_secret_post"] and
          (not is_binary(secret) or secret == "") ->
        {:error, :client_registration, :client_secret_required}

      method == "private_key_jwt" and not valid_assertion_provider?(assertion_provider) ->
        {:error, :client_registration, :client_assertion_provider_required}

      true ->
        with {:ok, issuer} <- normalize_client_issuer(client["issuer"]) do
          {:ok,
           %{
             client_id: client_id,
             client_secret: secret,
             token_endpoint_auth_method: method,
             assertion_provider: assertion_provider,
             issuer: issuer
           }}
        else
          {:error, reason} -> {:error, :client_registration, reason}
        end
    end
  end

  defp validate_registered_client(_client),
    do: {:error, :client_registration, :invalid_client_registration}

  defp bind_pre_registered_client(state, client, server_metadata) do
    issuer = server_metadata["issuer"]
    binding_key = {:pre_registered, client.client_id}

    cond do
      is_binary(client.issuer) and client.issuer != issuer ->
        {:error, :client_registration, :authorization_server_binding_mismatch}

      Map.get(state.credential_bindings, binding_key) in [nil, issuer] ->
        {:ok, put_in(state, [:credential_bindings, binding_key], issuer)}

      true ->
        {:error, :client_registration, :authorization_server_binding_mismatch}
    end
  end

  defp normalize_client_issuer(nil), do: {:ok, nil}
  defp normalize_client_issuer(issuer), do: validate_exact_https_url(issuer)

  defp valid_assertion_provider?(provider) when is_function(provider, 1), do: true

  defp valid_assertion_provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :assertion, 1)
  end

  defp valid_assertion_provider?(_provider), do: false

  defp valid_enterprise_provider?(provider) when is_function(provider, 1), do: true

  defp valid_enterprise_provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :identity_assertion, 1)
  end

  defp valid_enterprise_provider?(_provider), do: false

  defp validate_application_type(type) when type in ["native", "web"], do: :ok
  defp validate_application_type(_type), do: {:error, :invalid_application_type}

  defp redirect_application_type(redirect_uri) do
    if localhost?(URI.parse(redirect_uri).host), do: "native", else: "web"
  end

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
       state: state_token,
       issuer: server_metadata["recorded_issuer"] || server_metadata["issuer"],
       issuer_required?: server_metadata["authorization_response_iss_parameter_supported"] == true
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
         :ok <- validate_authorization_issuer(query["iss"], request),
         true <- secure_compare(query["state"], request.state),
         :ok <- reject_authorization_error(query),
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
         :ok <- validate_authorization_issuer(response["iss"], request),
         :ok <- validate_authorization_state(response["state"], request.state),
         :ok <- reject_authorization_error(response),
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

  defp validate_authorization_issuer(nil, %{issuer_required?: true}),
    do: {:error, :authorization_issuer_required}

  defp validate_authorization_issuer(nil, _request), do: :ok

  defp validate_authorization_issuer(actual, %{issuer: expected})
       when is_binary(actual) and is_binary(expected) do
    if actual == expected,
      do: :ok,
      else: {:error, :authorization_issuer_mismatch}
  end

  defp validate_authorization_issuer(_actual, _request),
    do: {:error, :authorization_issuer_mismatch}

  defp exchange_code(state, metadata, client, resource, code, verifier, scopes) do
    base_form =
      [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"redirect_uri", state.config.redirect_uri},
        {"client_id", client.client_id},
        {"code_verifier", verifier},
        {"resource", resource}
      ]

    with {:ok, form, headers} <-
           prepare_token_request(
             state,
             metadata,
             client,
             base_form,
             "authorization_code"
           ),
         {:ok, status, _headers, body} <-
           oauth_request(state, :post, metadata["token_endpoint"], form: form, headers: headers),
         :ok <- ensure_success_status(status),
         {:ok, token} <- decode_token_response(body, scopes, nil) do
      {:ok, token}
    else
      {:error, {:http_status, status}} -> {:error, :token_exchange, {:http_status, status}}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp exchange_client_credentials(state, metadata, client, resource, scopes) do
    base_form =
      [{"grant_type", "client_credentials"}, {"resource", resource}]
      |> maybe_append_scope(scopes)

    with {:ok, form, headers} <-
           prepare_token_request(
             state,
             metadata,
             client,
             base_form,
             "client_credentials"
           ),
         {:ok, status, _headers, body} <-
           oauth_request(state, :post, metadata["token_endpoint"], form: form, headers: headers),
         :ok <- ensure_success_status(status),
         {:ok, token} <- decode_token_response(body, scopes, nil) do
      {:ok, token}
    else
      {:error, {:http_status, status}} -> {:error, :token_exchange, {:http_status, status}}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp exchange_enterprise_identity(state, metadata, client, resource, scopes) do
    with {:ok, assertion} <- enterprise_identity_assertion(state, metadata, resource, scopes),
         {:ok, id_jag} <-
           exchange_identity_assertion(state, metadata, assertion, resource, scopes),
         {:ok, token} <-
           exchange_id_jag(state, metadata, client, resource, scopes, id_jag) do
      {:ok, token}
    else
      {:error, stage, reason} -> {:error, stage, reason}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp enterprise_identity_assertion(state, metadata, resource, scopes) do
    request = %EnterpriseManagedProvider.Request{
      resource: resource,
      authorization_server: metadata["issuer"],
      scopes: scopes
    }

    response =
      case state.config.grant.provider do
        provider when is_function(provider, 1) -> provider.(request)
        module when is_atom(module) -> module.identity_assertion(request)
      end

    case response do
      {:ok, assertion} -> normalize_enterprise_assertion(assertion)
      {:error, _reason} -> {:error, :authorization, :enterprise_identity_unavailable}
      _other -> {:error, :authorization, :invalid_enterprise_identity_response}
    end
  rescue
    _error -> {:error, :authorization, :enterprise_identity_provider_failed}
  catch
    _kind, _reason -> {:error, :authorization, :enterprise_identity_provider_failed}
  end

  defp normalize_enterprise_assertion(%EnterpriseManagedProvider.Assertion{} = assertion),
    do: assertion |> Map.from_struct() |> normalize_enterprise_assertion()

  defp normalize_enterprise_assertion(assertion) when is_map(assertion) do
    assertion = stringify_keys(assertion)
    headers = assertion["headers"] || []
    form = assertion["form"] || []

    with {:ok, token_endpoint} <- validate_preserved_https_url(assertion["token_endpoint"]),
         subject_token when is_binary(subject_token) and subject_token != "" <-
           assertion["subject_token"],
         subject_token_type when is_binary(subject_token_type) and subject_token_type != "" <-
           assertion["subject_token_type"],
         :ok <- validate_header_pairs(headers),
         :ok <- validate_form_pairs(form),
         :ok <- validate_enterprise_form_fields(form) do
      {:ok,
       %{
         token_endpoint: token_endpoint,
         subject_token: subject_token,
         subject_token_type: subject_token_type,
         headers: headers,
         form: form
       }}
    else
      {:error, stage, reason} -> {:error, stage, reason}
      {:error, reason} -> {:error, :authorization, reason}
      _other -> {:error, :authorization, :invalid_enterprise_identity_response}
    end
  end

  defp normalize_enterprise_assertion(_assertion),
    do: {:error, :authorization, :invalid_enterprise_identity_response}

  defp exchange_identity_assertion(state, metadata, assertion, resource, scopes) do
    form =
      [
        {"grant_type", @token_exchange_grant},
        {"requested_token_type", @id_jag_token_type},
        {"audience", metadata["recorded_issuer"] || metadata["issuer"]},
        {"resource", resource},
        {"subject_token", assertion.subject_token},
        {"subject_token_type", assertion.subject_token_type}
      ]
      |> maybe_append_scope(scopes)
      |> Kernel.++(assertion.form)

    with {:ok, status, _headers, body} <-
           oauth_request(
             state,
             :post,
             assertion.token_endpoint,
             form: form,
             headers: assertion.headers
           ),
         :ok <- ensure_success_status(status),
         {:ok, id_jag} <- decode_id_jag_response(body) do
      {:ok, id_jag}
    else
      {:error, {:http_status, status}} -> {:error, :token_exchange, {:http_status, status}}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp exchange_id_jag(state, metadata, client, resource, scopes, id_jag) do
    base_form = [
      {"grant_type", @jwt_bearer_grant},
      {"assertion", id_jag},
      {"client_id", client.client_id},
      {"resource", resource}
    ]

    with {:ok, form, headers} <-
           prepare_token_request(
             state,
             metadata,
             client,
             base_form,
             @jwt_bearer_grant
           ),
         {:ok, status, _headers, body} <-
           oauth_request(state, :post, metadata["token_endpoint"], form: form, headers: headers),
         :ok <- ensure_success_status(status),
         {:ok, token} <- decode_token_response(body, scopes, nil) do
      {:ok, token}
    else
      {:error, {:http_status, status}} -> {:error, :token_exchange, {:http_status, status}}
      {:error, reason} -> {:error, :token_exchange, sanitize_reason(reason)}
    end
  end

  defp decode_id_jag_response(body) do
    with {:ok, document} <- decode_json_object(body),
         true <- document["issued_token_type"] == @id_jag_token_type,
         token when is_binary(token) and token != "" <- document["access_token"] do
      {:ok, token}
    else
      false -> {:error, :invalid_identity_assertion_token_type}
      _other -> {:error, :invalid_identity_assertion_response}
    end
  end

  defp refresh_token(state, context, old_token) do
    client = context.client

    base_form =
      [
        {"grant_type", "refresh_token"},
        {"refresh_token", old_token["refresh_token"]},
        {"client_id", client.client_id},
        {"resource", context.resource}
      ]
      |> maybe_append_scope(old_token["scope"] || [])

    result =
      with {:ok, form, headers} <-
             prepare_token_request(
               state,
               context.server_metadata,
               client,
               base_form,
               "refresh_token"
             ),
           {:ok, status, _headers, body} <-
             oauth_request(
               state,
               :post,
               context.server_metadata["token_endpoint"],
               form: form,
               headers: headers
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
    with {:ok, grant_config} <- normalize_grant(Keyword.get(opts, :grant), opts),
         {:ok, authorization_server} <-
           validate_optional_authorization_server(Keyword.get(opts, :authorization_server)),
         {:ok, scopes} <- validate_scope_list(Keyword.get(opts, :scopes, [])),
         {:ok, application_type} <-
           normalize_application_type(Map.get(grant_config, :application_type), grant_config),
         {:ok, timeout_ms} <-
           positive_integer(Keyword.get(opts, :timeout_ms, @default_timeout_ms)),
         {:ok, max_body_bytes} <-
           positive_integer(Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)),
         :ok <- validate_requester(Keyword.get(opts, :requester)) do
      {:ok,
       %{
         grant: grant_config.grant,
         redirect_uri: grant_config.redirect_uri,
         registration: grant_config.registration,
         authorization_handler: grant_config.authorization_handler,
         authorization_server: authorization_server,
         scopes: scopes,
         application_type: application_type,
         requester: Keyword.get(opts, :requester),
         token_store: Keyword.get(opts, :token_store),
         timeout_ms: timeout_ms,
         max_body_bytes: max_body_bytes
       }}
    else
      {:error, reason} -> {:error, oauth_error(:configuration, reason)}
    end
  end

  defp normalize_grant(nil, opts), do: normalize_authorization_code_grant(%{}, opts)

  defp normalize_grant(:authorization_code, opts),
    do: normalize_authorization_code_grant(%{}, opts)

  defp normalize_grant({:authorization_code, grant_opts}, opts)
       when is_list(grant_opts) or is_map(grant_opts),
       do: normalize_authorization_code_grant(Map.new(grant_opts), opts)

  defp normalize_grant({:client_credentials, grant_opts}, _opts)
       when is_list(grant_opts) or is_map(grant_opts) do
    client =
      grant_opts
      |> Map.new()
      |> stringify_keys()
      |> normalize_client_auth_method()

    case validate_registered_client(client) do
      {:ok, %{token_endpoint_auth_method: method} = client}
      when method in ["client_secret_basic", "private_key_jwt"] ->
        {:ok,
         %{
           grant: %{type: :client_credentials, client: client},
           redirect_uri: nil,
           registration: {:pre_registered, client},
           authorization_handler: nil
         }}

      {:ok, _client} ->
        {:error, :client_credentials_auth_method_required}

      {:error, :client_registration, reason} ->
        {:error, reason}
    end
  end

  defp normalize_grant({:enterprise_managed, grant_opts}, opts)
       when is_list(grant_opts) or is_map(grant_opts) do
    grant_opts = Map.new(grant_opts)
    registration = config_value(grant_opts, :registration, opts)
    provider = config_value(grant_opts, :provider, opts)

    with {:ok, registration} <- normalize_registration(registration),
         :ok <- validate_enterprise_registration(registration),
         :ok <- validate_enterprise_provider(provider) do
      {:ok,
       %{
         grant: %{type: :enterprise_managed, provider: provider},
         redirect_uri: nil,
         registration: registration,
         authorization_handler: nil
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_grant(_grant, _opts), do: {:error, :invalid_oauth_grant}

  defp validate_enterprise_registration({:dynamic, _metadata}),
    do: {:error, :dynamic_registration_not_supported_for_enterprise_managed}

  defp validate_enterprise_registration(_registration), do: :ok

  defp validate_enterprise_provider(provider) do
    if valid_enterprise_provider?(provider),
      do: :ok,
      else: {:error, :enterprise_identity_provider_required}
  end

  defp normalize_authorization_code_grant(grant_opts, opts) do
    with {:ok, redirect_uri} <-
           validate_redirect_uri(config_value(grant_opts, :redirect_uri, opts)),
         {:ok, registration} <-
           normalize_registration(config_value(grant_opts, :registration, opts)),
         {:ok, authorization_handler} <-
           validate_authorization_handler(config_value(grant_opts, :authorization_handler, opts)) do
      {:ok,
       %{
         grant: %{type: :authorization_code},
         redirect_uri: redirect_uri,
         registration: registration,
         authorization_handler: authorization_handler,
         application_type: config_value(grant_opts, :application_type, opts)
       }}
    end
  end

  defp normalize_application_type(nil, %{redirect_uri: redirect_uri})
       when is_binary(redirect_uri),
       do: {:ok, redirect_application_type(redirect_uri)}

  defp normalize_application_type(nil, _grant_config), do: {:ok, nil}

  defp normalize_application_type(type, %{grant: %{type: :authorization_code}})
       when type in ["native", "web"],
       do: {:ok, type}

  defp normalize_application_type(_type, _grant_config), do: {:error, :invalid_application_type}

  defp config_value(map, key, fallback_opts) do
    Map.get(map, key) || Map.get(map, to_string(key)) || Keyword.get(fallback_opts, key)
  end

  defp normalize_client_auth_method(client) do
    case client["token_endpoint_auth_method"] do
      method when is_atom(method) ->
        Map.put(client, "token_endpoint_auth_method", Atom.to_string(method))

      _other ->
        client
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
  defp validate_optional_authorization_server(url), do: validate_exact_https_url(url)

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

  # Keep the established authorization-code store key stable for existing
  # custom stores. Extension grants need a discriminator because the same
  # client and resource can legitimately hold user and workload credentials.
  defp token_key(resource, issuer, client_id, :authorization_code),
    do: {resource, issuer, client_id}

  defp token_key(resource, issuer, client_id, grant),
    do: {resource, issuer, client_id, grant}

  defp reacquirable_grant?(grant),
    do: grant in [:client_credentials, :enterprise_managed]

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
    with {:ok, exact} <- validate_preserved_https_url(url),
         %URI{path: path} <- URI.parse(exact),
         true <- is_binary(path) and path not in ["", "/"] do
      {:ok, exact}
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

  defp validate_preserved_https_url(url) when is_binary(url) do
    case canonical_https_url(url) do
      {:ok, _canonical} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_preserved_https_url(_url), do: {:error, :invalid_url}

  defp validate_exact_https_url(url) when is_binary(url) do
    with {:ok, _canonical} <- canonical_https_url(url),
         %URI{query: nil} <- URI.parse(url) do
      {:ok, url}
    else
      %URI{} -> {:error, :issuer_query_forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_exact_https_url(_url), do: {:error, :invalid_url}

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
      case validate_exact_https_url(url) do
        {:ok, exact} -> {:cont, {:ok, acc ++ [exact]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_optional_https_endpoint(document, key) do
    case document[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        case validate_preserved_https_url(value) do
          {:ok, _canonical} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_endpoint}
    end
  end

  defp validate_optional_boolean(document, key) do
    case document[key] do
      value when value in [nil, true, false] -> :ok
      _other -> {:error, :invalid_authorization_server_metadata}
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

  defp prepare_token_request(
         _state,
         _metadata,
         %{token_endpoint_auth_method: "none"},
         form,
         _grant_type
       ) do
    {:ok, form, []}
  end

  defp prepare_token_request(
         _state,
         _metadata,
         %{token_endpoint_auth_method: "client_secret_basic"} = client,
         form,
         _grant_type
       ) do
    username = URI.encode_www_form(client.client_id)
    password = URI.encode_www_form(client.client_secret)

    {:ok, form, [{"authorization", "Basic " <> Base.encode64(username <> ":" <> password)}]}
  end

  defp prepare_token_request(
         _state,
         _metadata,
         %{token_endpoint_auth_method: "client_secret_post"} = client,
         form,
         _grant_type
       ) do
    {:ok, form ++ [{"client_secret", client.client_secret}], []}
  end

  defp prepare_token_request(
         _state,
         metadata,
         %{token_endpoint_auth_method: "private_key_jwt"} = client,
         form,
         grant_type
       ) do
    request = %ClientAssertionProvider.Request{
      client_id: client.client_id,
      token_endpoint: metadata["token_endpoint"],
      authorization_server: metadata["issuer"],
      signing_algorithms:
        normalize_scopes(metadata["token_endpoint_auth_signing_alg_values_supported"] || []),
      grant_type: grant_type
    }

    response =
      case client.assertion_provider do
        provider when is_function(provider, 1) -> provider.(request)
        module when is_atom(module) -> module.assertion(request)
      end

    case response do
      {:ok, assertion} when is_binary(assertion) and assertion != "" ->
        {:ok,
         form ++
           [
             {"client_assertion_type", @jwt_client_assertion_type},
             {"client_assertion", assertion}
           ], []}

      _other ->
        {:error, :client_assertion_failed}
    end
  rescue
    _error -> {:error, :client_assertion_failed}
  catch
    _kind, _reason -> {:error, :client_assertion_failed}
  end

  defp validate_header_pairs(pairs) when is_list(pairs) do
    if Enum.all?(pairs, fn
         {key, value} -> is_binary(key) and key != "" and is_binary(value)
         _other -> false
       end),
       do: :ok,
       else: {:error, :invalid_enterprise_request_headers}
  end

  defp validate_header_pairs(_pairs), do: {:error, :invalid_enterprise_request_headers}

  defp validate_form_pairs(pairs) when is_list(pairs) do
    if Enum.all?(pairs, fn
         {key, value} -> is_binary(key) and key != "" and is_binary(value)
         _other -> false
       end),
       do: :ok,
       else: {:error, :invalid_enterprise_request_form}
  end

  defp validate_form_pairs(_pairs), do: {:error, :invalid_enterprise_request_form}

  defp validate_enterprise_form_fields(form) do
    reserved = [
      "grant_type",
      "requested_token_type",
      "audience",
      "resource",
      "scope",
      "subject_token",
      "subject_token_type"
    ]

    if Enum.any?(form, fn {key, _value} -> key in reserved end),
      do: {:error, :enterprise_request_field_override},
      else: :ok
  end

  defp valid_string_list?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp valid_string_list?(_values), do: false

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

  defp validate_credential_listener(nil), do: :ok
  defp validate_credential_listener(pid) when is_pid(pid), do: :ok
  defp validate_credential_listener(_listener), do: {:error, :invalid_credential_listener}

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
