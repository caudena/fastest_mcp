defmodule FastestMCP.Client.OAuth.Flow do
  @moduledoc false
  # One authorization or refresh of one resource. The coordinator runs it in
  # a task, so network I/O and host callbacks never block the coordinator. A
  # flow starts from a snapshot (the config, the resource's stored context and
  # token, and the cached dynamic registrations) and returns `{result, flow}`:
  # the coordinator stores a new token under `flow.context`, drops the stored
  # token when `flow.drop?`, and keeps `flow.registrations`. Binding
  # pre-registered credentials to an issuer is the one step that asks the
  # coordinator, so concurrent flows cannot bind a client to two servers.

  import FastestMCP.Util, only: [secure_equal?: 2, stringify_keys: 1]

  alias FastestMCP.Client.OAuth.AuthorizationHandler
  alias FastestMCP.Client.OAuth.Config
  alias FastestMCP.Client.OAuth.EnterpriseManagedProvider
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Client.OAuth.TokenEndpoint
  alias FastestMCP.Client.OAuth.URL
  alias FastestMCP.MIME

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @token_exchange "urn:ietf:params:oauth:grant-type:token-exchange"
  @id_jag "urn:ietf:params:oauth:token-type:id-jag"
  @id_jag_profile "urn:ietf:params:oauth:grant-profile:id-jag"
  @reserved_exchange_fields ~w(grant_type requested_token_type audience resource scope
                               subject_token subject_token_type)

  @enforce_keys [:config, :coordinator, :resource]
  defstruct [
    :config,
    :coordinator,
    :resource,
    :context,
    :token,
    :protected_resource,
    :server_metadata,
    :client,
    challenge: %{resource_metadata: nil, scopes: [], error: nil},
    extra_scopes: [],
    scopes: [],
    refresh: :never,
    drop?: false,
    registrations: %{}
  ]

  # `refresh: :only` refreshes the stored token, `:first` authorizes when a
  # refresh is impossible or fails, and `:never` authorizes.
  def run(%__MODULE__{refresh: :only} = flow) do
    case refresh(flow) do
      {:ok, token} -> {{:ok, token}, flow}
      {:error, error} -> {{:error, error}, %{flow | drop?: true}}
    end
  end

  def run(%__MODULE__{refresh: :first, token: %{"refresh_token" => refresh_token}} = flow)
      when is_binary(refresh_token) do
    case refresh(flow) do
      {:ok, token} -> {{:ok, token}, flow}
      {:error, _error} -> authorize(%{flow | token: nil, drop?: true})
    end
  end

  def run(flow), do: authorize(flow)

  # The Bearer challenge of a 401 or 403 response.
  def challenge(headers) do
    params =
      headers
      |> header_values("www-authenticate")
      |> Enum.find("", &Regex.match?(~r/(?:^|,)\s*Bearer(?:\s|$)/i, &1))
      |> auth_params()

    %{
      resource_metadata: params["resource_metadata"],
      scopes: params["scope"] || [],
      error: params["error"]
    }
  end

  defp refresh(%{context: %{client: client} = context, token: token} = flow) do
    scopes = token["scope"] || []
    flow = %{flow | server_metadata: context.server_metadata, client: client, scopes: scopes}
    refresh_token = token["refresh_token"]
    params = [{"refresh_token", refresh_token}, {"client_id", client.client_id}]
    params = with_scope(params ++ [{"resource", flow.resource}], scopes)
    TokenEndpoint.exchange(flow, "refresh_token", params, refresh_token)
  end

  defp authorize(flow) do
    with {:ok, flow} <- discover(flow),
         {:ok, flow} <- register(flow) do
      flow = %{flow | scopes: scopes(flow)}

      case exchange(flow) do
        {:ok, token} -> {{:ok, token}, %{flow | context: context(flow)}}
        {:error, error} -> {{:error, error}, flow}
      end
    else
      {:error, error} -> {{:error, error}, flow}
    end
  end

  ## Discovery

  defp discover(flow) do
    with {:ok, resource} <- protected_resource(flow),
         {:ok, issuer} <- authorization_server(resource, flow.config.authorization_server),
         {:ok, metadata} <- server_metadata(flow.config, issuer) do
      {:ok, %{flow | protected_resource: resource, server_metadata: metadata}}
    end
  end

  # A challenge's metadata URL is the only candidate; failing it fails.
  defp protected_resource(%{challenge: %{resource_metadata: url}, resource: resource} = flow) do
    candidates =
      if is_binary(url) and url != "",
        do: [url],
        else: URL.resource_metadata_urls(resource)

    first_document(
      flow.config,
      candidates,
      :protected_resource_discovery,
      is_binary(url),
      &URL.resource_metadata(&1, resource),
      &protected_resource_document(&1, resource)
    )
  end

  defp authorization_server(%{"authorization_servers" => [first | _rest]}, nil), do: {:ok, first}

  defp authorization_server(%{"authorization_servers" => servers}, selected) do
    if selected in servers,
      do: {:ok, selected},
      else: error(:authorization, :authorization_server_not_advertised)
  end

  defp server_metadata(config, issuer) do
    first_document(
      config,
      URL.server_metadata_urls(issuer),
      :authorization_server_discovery,
      false,
      &URL.https/1,
      &server_document(&1, issuer, config)
    )
  end

  # The first candidate document that exists: a 404 moves on, as does any
  # other failure unless `halt?`.
  defp first_document(config, candidates, stage, halt?, check_url, validate) do
    Enum.reduce_while(candidates, error(stage, :metadata_not_found), fn url, _last ->
      case get_document(config, url, check_url) do
        {:ok, document} ->
          case validate.(document) do
            {:ok, document} -> {:halt, {:ok, document}}
            {:error, reason} -> {:halt, error(stage, reason)}
          end

        {:error, {:http_status, 404}} ->
          {:cont, error(stage, :metadata_not_found)}

        {:error, reason} ->
          if halt?, do: {:halt, error(stage, reason)}, else: {:cont, error(stage, reason)}
      end
    end)
  end

  defp get_document(config, url, check_url) do
    with {:ok, url} <- check_url.(url),
         {:ok, 200, headers, body} <- TokenEndpoint.request(config, :get, url),
         :ok <- json_content_type(header_values(headers, "content-type")),
         {:ok, document} <- TokenEndpoint.json(body) do
      {:ok, document}
    else
      {:ok, status, _headers, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp json_content_type([]), do: {:error, :json_content_type_required}

  defp json_content_type([type | _rest]),
    do: check(MIME.json?(type), :invalid_json_content_type)

  defp protected_resource_document(document, requested) do
    with resource when is_binary(resource) <- document["resource"],
         {:ok, resource} <- URL.resource(resource),
         true <- URL.covers?(resource, requested),
         [_ | _] = servers <- document["authorization_servers"] || [],
         :ok <- all(servers, &URL.exact_https/1) do
      {:ok, %{document | "resource" => resource}}
    else
      nil -> {:error, :resource_required}
      false -> {:error, :resource_mismatch}
      [] -> {:error, :authorization_servers_required}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_protected_resource_metadata}
    end
  end

  defp server_document(document, issuer, config) do
    with recorded when is_binary(recorded) <- document["issuer"],
         {:ok, _issuer} <- URL.exact_https(recorded),
         true <- recorded == issuer,
         {:ok, _endpoint} <- URL.preserved_https(document["token_endpoint"]),
         :ok <- optional_https(document["registration_endpoint"]),
         :ok <-
           check(
             document["authorization_response_iss_parameter_supported"] in [nil, true, false],
             :invalid_authorization_server_metadata
           ),
         :ok <- grant_metadata(document, config) do
      {:ok, document}
    else
      false -> {:error, :issuer_mismatch}
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :authorization_server_metadata_incomplete}
    end
  end

  defp optional_https(nil), do: :ok

  defp optional_https(url) when is_binary(url),
    do: with({:ok, _url} <- URL.preserved_https(url), do: :ok)

  defp optional_https(_url), do: {:error, :invalid_endpoint}

  defp grant_metadata(document, %{grant: :authorization_code}) do
    with {:ok, _endpoint} <- URL.preserved_https(document["authorization_endpoint"]),
         methods when is_list(methods) <- document["code_challenge_methods_supported"],
         true <- "S256" in methods do
      :ok
    else
      nil -> {:error, :authorization_server_metadata_incomplete}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :pkce_s256_required}
    end
  end

  defp grant_metadata(document, %{grant: :client_credentials, registration: {_, client}}) do
    methods = document["token_endpoint_auth_methods_supported"]
    method = client.token_endpoint_auth_method
    algorithms = document["token_endpoint_auth_signing_alg_values_supported"]

    cond do
      not is_list(methods) ->
        {:error, :token_endpoint_auth_methods_required}

      method not in methods ->
        {:error, :token_endpoint_auth_method_not_supported}

      method == "private_key_jwt" and
          not (is_list(algorithms) and algorithms != [] and Enum.all?(algorithms, &present?/1)) ->
        {:error, :token_endpoint_auth_signing_algorithms_required}

      true ->
        :ok
    end
  end

  defp grant_metadata(document, %{grant: :enterprise_managed}) do
    case document["authorization_grant_profiles_supported"] do
      nil ->
        :ok

      profiles when is_list(profiles) ->
        cond do
          @id_jag_profile not in profiles ->
            {:error, :enterprise_managed_grant_not_supported}

          @jwt_bearer not in List.wrap(document["grant_types_supported"]) ->
            {:error, :enterprise_managed_grant_metadata_inconsistent}

          true ->
            :ok
        end

      _other ->
        {:error, :invalid_authorization_server_metadata}
    end
  end

  ## Registration

  defp register(%{config: %{registration: {:pre_registered, client}}} = flow) do
    with {:ok, client} <- registration_result(Config.client(client)),
         :ok <- bind(flow, client) do
      {:ok, %{flow | client: client}}
    end
  end

  defp register(%{config: %{registration: {:client_metadata_document, client_id}}} = flow) do
    supported? = flow.server_metadata["client_id_metadata_document_supported"] == true

    with :ok <- check(supported?, :client_metadata_document_unsupported),
         {:ok, client_id} <- URL.client_id_document(client_id),
         {:ok, client} <- Config.client(client_id: client_id) do
      {:ok, %{flow | client: client}}
    else
      {:error, reason} -> error(:client_registration, reason)
    end
  end

  defp register(%{config: %{registration: {:dynamic, metadata}}} = flow) do
    key = {flow.server_metadata["issuer"], metadata}

    case flow.registrations do
      %{^key => client} ->
        {:ok, %{flow | client: client}}

      _unregistered ->
        with {:ok, client} <- register_dynamically(flow, metadata),
             do:
               {:ok,
                %{flow | client: client, registrations: Map.put(flow.registrations, key, client)}}
    end
  end

  defp register_dynamically(flow, metadata) do
    case flow.server_metadata["registration_endpoint"] do
      endpoint when is_binary(endpoint) ->
        payload =
          metadata
          |> stringify_keys()
          |> Map.put_new("client_name", "FastestMCP Client")
          |> Map.put_new("redirect_uris", [flow.config.redirect_uri])
          |> Map.put_new("grant_types", ["authorization_code", "refresh_token"])
          |> Map.put_new("response_types", ["code"])
          |> Map.put_new("token_endpoint_auth_method", "none")
          |> Map.put_new("application_type", flow.config.application_type)

        with :ok <-
               check(payload["application_type"] in ["native", "web"], :invalid_application_type),
             {:ok, body} <- TokenEndpoint.post(flow.config, endpoint, json: payload),
             {:ok, document} <- TokenEndpoint.json(body) do
          registration_result(Config.client(document))
        else
          {:error, reason} -> error(:client_registration, reason)
        end

      _none ->
        error(:client_registration, :dynamic_registration_unsupported)
    end
  end

  defp registration_result({:ok, client}), do: {:ok, client}
  defp registration_result({:error, reason}), do: error(:client_registration, reason)

  # Pre-registered credentials stay with their configured issuer, or the
  # first authorization server that used them.
  defp bind(flow, client) do
    issuer = flow.server_metadata["issuer"]

    if client.issuer in [nil, issuer] and
         GenServer.call(flow.coordinator, {:bind, client.client_id, issuer}) == :ok,
       do: :ok,
       else: error(:client_registration, :authorization_server_binding_mismatch)
  end

  ## Grants

  defp exchange(%{config: %{grant: :authorization_code}} = flow) do
    verifier = random_token(64)
    state = random_token(32)
    redirect_uri = flow.config.redirect_uri

    query =
      with_scope(
        [
          {"response_type", "code"},
          {"client_id", flow.client.client_id},
          {"redirect_uri", redirect_uri},
          {"code_challenge", Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)},
          {"code_challenge_method", "S256"},
          {"resource", flow.resource},
          {"state", state}
        ],
        flow.scopes
      )

    url =
      flow.server_metadata["authorization_endpoint"]
      |> URI.parse()
      |> URI.append_query(URI.encode_query(query, :rfc3986))
      |> URI.to_string()

    request = %AuthorizationHandler.Request{
      authorization_url: url,
      redirect_uri: redirect_uri,
      resource: flow.resource,
      scopes: flow.scopes
    }

    with {:ok, code} <- authorization_code(flow, request, state) do
      TokenEndpoint.exchange(flow, "authorization_code", [
        {"code", code},
        {"redirect_uri", redirect_uri},
        {"client_id", flow.client.client_id},
        {"code_verifier", verifier},
        {"resource", flow.resource}
      ])
    end
  end

  # The token stays unrefreshable: an expired one is reacquired.
  defp exchange(%{config: %{grant: :client_credentials}} = flow) do
    params = with_scope([{"resource", flow.resource}], flow.scopes)

    with {:ok, token} <- TokenEndpoint.exchange(flow, "client_credentials", params),
         do: {:ok, %{token | "refresh_token" => nil}}
  end

  defp exchange(%{config: %{grant: :enterprise_managed}} = flow) do
    params = [{"client_id", flow.client.client_id}, {"resource", flow.resource}]

    with {:ok, assertion} <- identity_assertion(flow),
         {:ok, id_jag} <- id_jag(flow, assertion),
         {:ok, token} <-
           TokenEndpoint.exchange(flow, @jwt_bearer, [{"assertion", id_jag} | params]),
         do: {:ok, %{token | "refresh_token" => nil}}
  end

  # The host returns the final redirect URI, or its parameters with the
  # `redirect_uri` it observed.
  defp authorization_code(flow, request, state) do
    flow.config.authorization_handler
    |> Config.invoke(:authorize, request)
    |> redirect_code(flow.server_metadata, request, state)
  catch
    _kind, _reason -> error(:authorization, :authorization_handler_failed)
  end

  defp redirect_code({:ok, redirect}, metadata, request, state) when is_binary(redirect) do
    query = URI.decode_query(URI.parse(redirect).query || "")
    redirect_code({:ok, Map.put(query, "redirect_uri", redirect)}, metadata, request, state)
  end

  defp redirect_code({:ok, %{} = response}, metadata, request, state) do
    response = stringify_keys(response)

    with {:ok, redirect} <- present(response["redirect_uri"], :authorization_redirect_required),
         :ok <- URL.same_redirect(request.redirect_uri, redirect),
         :ok <- authorization_issuer(response["iss"], metadata),
         :ok <- check(secure_equal?(response["state"], state), :state_mismatch),
         :ok <- check(not is_binary(response["error"]), :authorization_server_error),
         {:ok, code} <- present(response["code"], :authorization_code_required) do
      {:ok, code}
    else
      {:error, reason} -> error(:authorization, reason)
    end
  end

  defp redirect_code({:error, _reason}, _metadata, _request, _state),
    do: error(:authorization, :authorization_declined)

  defp redirect_code(_response, _metadata, _request, _state),
    do: error(:authorization, :invalid_authorization_response)

  # RFC 9207: a present `iss` must match; advertised support requires it.
  defp authorization_issuer(nil, metadata) do
    check(
      metadata["authorization_response_iss_parameter_supported"] != true,
      :authorization_issuer_required
    )
  end

  defp authorization_issuer(issuer, metadata),
    do: check(issuer == metadata["issuer"], :authorization_issuer_mismatch)

  defp identity_assertion(flow) do
    request = %EnterpriseManagedProvider.Request{
      resource: flow.resource,
      authorization_server: flow.server_metadata["issuer"],
      scopes: flow.scopes
    }

    case Config.invoke(flow.config.provider, :identity_assertion, request) do
      {:ok, assertion} -> assertion(assertion)
      {:error, _reason} -> error(:authorization, :enterprise_identity_unavailable)
      _other -> error(:authorization, :invalid_enterprise_identity_response)
    end
  catch
    _kind, _reason -> error(:authorization, :enterprise_identity_provider_failed)
  end

  defp assertion(%EnterpriseManagedProvider.Assertion{} = assertion),
    do: assertion |> Map.from_struct() |> assertion()

  defp assertion(%{} = assertion) do
    assertion = stringify_keys(assertion)
    headers = assertion["headers"] || []
    form = assertion["form"] || []
    invalid = :invalid_enterprise_identity_response

    with {:ok, endpoint} <- URL.preserved_https(assertion["token_endpoint"]),
         {:ok, subject_token} <- present(assertion["subject_token"], invalid),
         {:ok, subject_token_type} <- present(assertion["subject_token_type"], invalid),
         :ok <- check(pairs?(headers), :invalid_enterprise_request_headers),
         :ok <- check(pairs?(form), :invalid_enterprise_request_form),
         :ok <-
           check(
             not Enum.any?(form, fn {key, _value} -> key in @reserved_exchange_fields end),
             :enterprise_request_field_override
           ) do
      {:ok,
       %{
         token_endpoint: endpoint,
         subject_token: subject_token,
         subject_token_type: subject_token_type,
         headers: headers,
         form: form
       }}
    else
      {:error, reason} -> error(:authorization, reason)
    end
  end

  defp assertion(_assertion), do: error(:authorization, :invalid_enterprise_identity_response)

  # RFC 8693 exchange of the host's identity assertion for an ID-JAG.
  defp id_jag(flow, assertion) do
    form =
      with_scope(
        [
          {"grant_type", @token_exchange},
          {"requested_token_type", @id_jag},
          {"audience", flow.server_metadata["issuer"]},
          {"resource", flow.resource},
          {"subject_token", assertion.subject_token},
          {"subject_token_type", assertion.subject_token_type}
        ],
        flow.scopes
      ) ++ assertion.form

    with {:ok, body} <-
           TokenEndpoint.post(flow.config, assertion.token_endpoint,
             form: form,
             headers: assertion.headers
           ) do
      case TokenEndpoint.json(body) do
        {:ok, %{"issued_token_type" => @id_jag, "access_token" => id_jag}}
        when is_binary(id_jag) and id_jag != "" ->
          {:ok, id_jag}

        {:ok, %{"issued_token_type" => @id_jag}} ->
          error(:token_exchange, :invalid_identity_assertion_response)

        {:ok, _document} ->
          error(:token_exchange, :invalid_identity_assertion_token_type)

        {:error, _reason} ->
          error(:token_exchange, :invalid_identity_assertion_response)
      end
    else
      {:error, reason} -> error(:token_exchange, reason)
    end
  end

  ## Helpers

  # Configured scopes replace the resource's advertised ones; a challenge
  # narrows them to what it asks. Stored and requested scopes are kept.
  defp scopes(flow) do
    challenge = TokenEndpoint.scopes(flow.challenge.scopes)

    base =
      cond do
        flow.config.scopes != [] -> flow.config.scopes
        challenge != [] -> []
        true -> flow.protected_resource["scopes_supported"]
      end

    [base, challenge, (flow.token || %{})["scope"], flow.extra_scopes]
    |> Enum.flat_map(&TokenEndpoint.scopes/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp context(flow) do
    issuer = flow.server_metadata["issuer"]

    %{
      resource: flow.resource,
      server_metadata: flow.server_metadata,
      client: flow.client,
      grant: flow.config.grant,
      token_key: token_key(flow.resource, issuer, flow.client.client_id, flow.config.grant)
    }
  end

  # The authorization-code key predates the extension grants; they add a
  # discriminator because one client may hold user and workload tokens.
  defp token_key(resource, issuer, client_id, :authorization_code),
    do: {resource, issuer, client_id}

  defp token_key(resource, issuer, client_id, grant), do: {resource, issuer, client_id, grant}

  defp with_scope(pairs, []), do: pairs
  defp with_scope(pairs, scopes), do: pairs ++ [{"scope", Enum.join(scopes, " ")}]

  defp header_values(headers, name) when is_map(headers) do
    for {key, values} <- headers,
        String.downcase(to_string(key)) == name,
        value <- List.wrap(values),
        do: to_string(value)
  end

  defp header_values(headers, name) when is_list(headers) do
    for {key, value} <- headers, String.downcase(to_string(key)) == name, do: to_string(value)
  end

  defp header_values(_headers, _name), do: []

  defp auth_params(header) do
    ~r/([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:\\.|[^"])*)"|([^,\s]+))/
    |> Regex.scan(header)
    |> Map.new(fn
      [_match, name, "", token] -> {String.downcase(name), token}
      [_match, name, quoted | _token] -> {String.downcase(name), unquote_value(quoted)}
    end)
  end

  defp unquote_value(value),
    do: value |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp pairs?(pairs) do
    is_list(pairs) and
      Enum.all?(
        pairs,
        &match?({key, value} when is_binary(key) and key != "" and is_binary(value), &1)
      )
  end

  defp all(values, validate) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate.(value) do
        {:ok, _value} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp present(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, reason), do: {:error, reason}

  defp present?(value), do: is_binary(value) and value != ""

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp error(stage, reason), do: {:error, Error.exception(stage: stage, reason: reason)}
end
