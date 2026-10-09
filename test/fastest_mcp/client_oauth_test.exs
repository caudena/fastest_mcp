defmodule FastestMCP.ClientOAuthTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Test.ClientProbe

  alias FastestMCP.Client
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Protocol.Extensions

  defmodule ChallengePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, "")
    end
  end

  @resource "https://mcp.example.com/public/mcp"
  @resource_metadata "https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp"
  @issuer "https://auth.example.com/tenant"
  @server_metadata "https://auth.example.com/.well-known/oauth-authorization-server/tenant"

  test "discovers metadata and sends PKCE S256 and resource indicators" do
    test_pid = self()

    requester = fn method, url, opts ->
      send(test_pid, {:oauth_http, method, url, opts})
      oauth_response(method, url, opts)
    end

    authorization_handler = fn request ->
      send(test_pid, {:authorization_request, request})
      query = URI.parse(request.authorization_url).query |> URI.decode_query()

      {:ok,
       request.redirect_uri <>
         "?" <> URI.encode_query(%{"code" => "authorization-code", "state" => query["state"]})}
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               redirect_uri: "http://127.0.0.1:8765/callback",
               registration: {:pre_registered, client_id: "test-client"},
               authorization_handler: authorization_handler,
               requester: requester
             )

    headers = [
      {"www-authenticate",
       ~s(Bearer resource_metadata="#{@resource_metadata}", scope="files:read files:write", error="invalid_token")}
    ]

    assert {:ok, "Bearer access-one"} =
             OAuth.handle_unauthorized(oauth, @resource, headers)

    assert_receive {:oauth_http, :get, @resource_metadata, _opts}
    assert_receive {:oauth_http, :get, @server_metadata, _opts}

    assert_receive {:authorization_request, request}
    query = URI.parse(request.authorization_url).query |> URI.decode_query()
    assert query["response_type"] == "code"
    assert query["client_id"] == "test-client"
    assert query["redirect_uri"] == "http://127.0.0.1:8765/callback"
    assert query["resource"] == @resource
    assert query["scope"] == "files:read files:write"
    assert query["code_challenge_method"] == "S256"
    assert byte_size(query["code_challenge"]) == 43
    assert is_binary(query["state"])

    assert_receive {:oauth_http, :post, "https://auth.example.com/token", token_opts}
    token_form = Map.new(token_opts[:form])
    assert token_form["grant_type"] == "authorization_code"
    assert token_form["code"] == "authorization-code"
    assert token_form["resource"] == @resource
    assert token_form["client_id"] == "test-client"
    assert byte_size(token_form["code_verifier"]) >= 43
    refute Map.has_key?(token_form, "client_secret")

    assert {:ok, "Bearer access-one"} = OAuth.authorization_header(oauth, @resource)
  end

  test "refreshes expiring tokens and rotates refresh credentials" do
    test_pid = self()

    requester = fn method, url, opts ->
      send(test_pid, {:oauth_http, method, url, opts})

      case {method, url, Map.new(opts[:form] || [])} do
        {:post, "https://auth.example.com/token", %{"grant_type" => "authorization_code"}} ->
          json_response(%{
            "access_token" => "short-lived",
            "token_type" => "Bearer",
            "refresh_token" => "refresh-one",
            "expires_in" => 1,
            "scope" => "files:read"
          })

        {:post, "https://auth.example.com/token", %{"grant_type" => "refresh_token"} = form} ->
          assert form["refresh_token"] == "refresh-one"
          assert form["resource"] == @resource

          json_response(%{
            "access_token" => "refreshed",
            "token_type" => "Bearer",
            "refresh_token" => "refresh-two",
            "expires_in" => 3600,
            "scope" => "files:read"
          })

        _other ->
          oauth_response(method, url, opts)
      end
    end

    assert {:ok, oauth} =
             OAuth.start_link(oauth_opts(requester, credential_listener: self()))

    assert {:ok, "Bearer short-lived"} = OAuth.authorize(oauth, @resource)
    assert_receive :oauth_credentials_refreshed

    assert_receive {:oauth_http, :post, "https://auth.example.com/token", authorization_opts}
    assert Map.new(authorization_opts[:form])["grant_type"] == "authorization_code"

    assert {:ok, "Bearer refreshed"} = OAuth.authorization_header(oauth, @resource)
    assert_receive :oauth_credentials_refreshed

    assert_receive {:oauth_http, :post, "https://auth.example.com/token", refresh_opts}
    assert Map.new(refresh_opts[:form])["grant_type"] == "refresh_token"
    assert {:ok, "Bearer refreshed"} = OAuth.authorization_header(oauth, @resource)
    refute_receive :oauth_credentials_refreshed, 50
  end

  test "rejects a state mismatch without exposing the authorization code" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 authorization_handler: fn request ->
                   {:ok,
                    %{
                      code: "must-not-appear",
                      state: "wrong-state",
                      redirect_uri: request.redirect_uri
                    }}
                 end
               )
             )

    assert {:error, %Error{stage: :authorization, reason: :state_mismatch} = error} =
             OAuth.authorize(oauth, @resource)

    refute Exception.message(error) =~ "must-not-appear"
    assert :none = OAuth.authorization_header(oauth, @resource)
  end

  test "structured authorization responses require and validate the observed redirect URI" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end

    for {response, expected_reason} <- [
          {
            fn _request, state ->
              %{code: "must-not-appear", state: state}
            end,
            :authorization_redirect_required
          },
          {
            fn _request, state ->
              %{
                code: "must-not-appear",
                state: state,
                redirect_uri: "http://127.0.0.1:8765/different-callback"
              }
            end,
            :state_or_redirect_mismatch
          }
        ] do
      authorization_handler = fn request ->
        state =
          request.authorization_url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("state")

        {:ok, response.(request, state)}
      end

      assert {:ok, oauth} =
               OAuth.start_link(
                 oauth_opts(requester, authorization_handler: authorization_handler)
               )

      assert {:error, %Error{stage: :authorization, reason: ^expected_reason}} =
               OAuth.authorize(oauth, @resource)

      assert :none = OAuth.authorization_header(oauth, @resource)
      GenServer.stop(oauth)
    end
  end

  test "refuses authorization servers that do not advertise PKCE S256" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        json_response(%{
          "issuer" => @issuer,
          "authorization_endpoint" => "https://auth.example.com/authorize",
          "token_endpoint" => "https://auth.example.com/token"
        })
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    assert {:error,
            %Error{
              stage: :authorization_server_discovery,
              reason: :authorization_server_metadata_incomplete
            }} = OAuth.authorize(oauth, @resource)
  end

  test "supports explicit dynamic registration" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "registration_endpoint" => "https://auth.example.com/register"
        })

      :post, "https://auth.example.com/register", opts ->
        send(test_pid, {:registration, opts[:json]})

        json_response(%{
          "client_id" => "dynamic-client",
          "token_endpoint_auth_method" => "none"
        })

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:token_form, Map.new(opts[:form])})
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               redirect_uri: "http://localhost:8765/callback",
               registration: {:dynamic, %{client_name: "Example Host"}},
               authorization_handler: successful_authorization_handler(),
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

    assert_receive {:registration,
                    %{
                      "client_name" => "Example Host",
                      "redirect_uris" => ["http://localhost:8765/callback"],
                      "application_type" => "native"
                    }}

    assert_receive {:token_form, %{"client_id" => "dynamic-client"}}
  end

  test "derives web application_type for remote DCR redirects" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "registration_endpoint" => "https://auth.example.com/register"
        })

      :post, "https://auth.example.com/register", opts ->
        send(test_pid, {:remote_registration, opts[:json]})
        json_response(%{"client_id" => "web-client"})

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               redirect_uri: "https://client.example.com/callback",
               registration: {:dynamic, %{}},
               authorization_handler: successful_authorization_handler(),
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)
    assert_receive {:remote_registration, %{"application_type" => "web"}}
  end

  test "rejects an invalid explicit DCR application_type before registration" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "registration_endpoint" => "https://auth.example.com/register"
        })

      :post, "https://auth.example.com/register", _opts ->
        send(test_pid, :unexpected_registration)
        json_response(%{"client_id" => "bad-client"})
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 registration: {:dynamic, %{application_type: "service"}}
               )
             )

    assert {:error, %Error{stage: :client_registration, reason: :invalid_application_type}} =
             OAuth.authorize(oauth, @resource)

    refute_receive :unexpected_registration
  end

  test "allows an explicit DCR application_type override" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "registration_endpoint" => "https://auth.example.com/register"
        })

      :post, "https://auth.example.com/register", opts ->
        send(test_pid, {:overridden_application_type, opts[:json]["application_type"]})
        json_response(%{"client_id" => "override-client"})

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 grant:
                   {:authorization_code, registration: {:dynamic, %{}}, application_type: "web"}
               )
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)
    assert_receive {:overridden_application_type, "web"}
  end

  test "supports Client ID Metadata Documents only when advertised" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{"client_id_metadata_document_supported" => true})

      :post, "https://auth.example.com/token", opts ->
        assert Map.new(opts[:form])["client_id"] == "https://client.example.com/oauth/client.json"
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               redirect_uri: "https://client.example.com/callback",
               registration:
                 {:client_metadata_document, "https://client.example.com/oauth/client.json"},
               authorization_handler: successful_authorization_handler(),
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)
  end

  test "tries the required OIDC path-insertion endpoint before path appending" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, "https://auth.example.com/.well-known/oauth-authorization-server/tenant", _opts ->
        {:ok, 404, [{"content-type", "application/json"}], "{}"}

      :get, "https://auth.example.com/.well-known/openid-configuration/tenant", _opts ->
        send(test_pid, :oidc_path_insertion)
        authorization_server_response()

      :get, "https://auth.example.com/tenant/.well-known/openid-configuration", _opts ->
        send(test_pid, :oidc_path_appending)
        authorization_server_response()

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)
    assert_receive :oidc_path_insertion
    refute_receive :oidc_path_appending
  end

  test "a challenged scope set is authoritative over broader resource metadata" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        json_response(%{
          "resource" => @resource,
          "authorization_servers" => [@issuer],
          "scopes_supported" => ["mcp:basic", "mcp:admin"]
        })

      :get, @server_metadata, _opts ->
        authorization_server_response()

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    authorization_handler = fn request ->
      query = URI.parse(request.authorization_url).query |> URI.decode_query()
      send(test_pid, {:requested_scope, query["scope"]})

      {:ok,
       %{
         code: "authorization-code",
         state: query["state"],
         redirect_uri: request.redirect_uri
       }}
    end

    assert {:ok, oauth} =
             OAuth.start_link(oauth_opts(requester, authorization_handler: authorization_handler))

    challenge = [{"www-authenticate", ~s(Bearer scope="mcp:basic")}]
    assert {:ok, "Bearer access-one"} = OAuth.handle_unauthorized(oauth, @resource, challenge)
    assert_receive {:requested_scope, "mcp:basic"}
  end

  test "configured base scopes are retained during insufficient-scope step-up" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response()

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    authorization_handler = fn request ->
      query = URI.parse(request.authorization_url).query |> URI.decode_query()
      send(test_pid, {:step_up_scope, query["scope"]})

      {:ok,
       %{
         code: "authorization-code",
         state: query["state"],
         redirect_uri: request.redirect_uri
       }}
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 scopes: ["mcp:base"],
                 authorization_handler: authorization_handler
               )
             )

    challenge = [
      {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="mcp:admin")}
    ]

    assert {:ok, "Bearer access-one"} = OAuth.handle_unauthorized(oauth, @resource, challenge)
    assert_receive {:step_up_scope, "mcp:admin mcp:base"}
  end

  test "accepts root protected-resource metadata for an endpoint on the same origin" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        json_response(%{
          "resource" => "https://mcp.example.com",
          "authorization_servers" => [@issuer]
        })

      :get, @server_metadata, _opts ->
        authorization_server_response()

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:root_metadata_token_form, Map.new(opts[:form])})
        token_response()
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

    assert_receive {:root_metadata_token_form, %{"resource" => @resource}}
  end

  test "canonicalizes a root resource indicator without a trailing slash" do
    test_pid = self()
    canonical_resource = "https://mcp.example.com"

    requester = fn
      :get, url, _opts
      when url in [
             "https://mcp.example.com/.well-known/oauth-protected-resource/",
             "https://mcp.example.com/.well-known/oauth-protected-resource"
           ] ->
        json_response(%{
          "resource" => canonical_resource,
          "authorization_servers" => [@issuer]
        })

      :get, @server_metadata, _opts ->
        authorization_server_response()

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:canonical_root_token_form, Map.new(opts[:form])})
        token_response()
    end

    authorization_handler = fn request ->
      send(test_pid, {:canonical_root_authorization, request})
      query = request.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      {:ok,
       request.redirect_uri <>
         "?" <> URI.encode_query(%{"code" => "authorization-code", "state" => query["state"]})}
    end

    assert {:ok, oauth} =
             OAuth.start_link(oauth_opts(requester, authorization_handler: authorization_handler))

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, "HTTPS://MCP.EXAMPLE.COM:443/")

    assert_receive {:canonical_root_authorization, request}
    query = request.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert request.resource == canonical_resource
    assert query["resource"] == canonical_resource

    assert_receive {:canonical_root_token_form, %{"resource" => ^canonical_resource}}

    assert {:ok, "Bearer access-one"} =
             OAuth.authorization_header(oauth, canonical_resource <> "/")
  end

  test "rejects a sibling path as protected-resource metadata" do
    requester = fn
      :get, @resource_metadata, _opts ->
        json_response(%{
          "resource" => "https://mcp.example.com/other",
          "authorization_servers" => [@issuer]
        })
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    assert {:error, %Error{stage: :protected_resource_discovery, reason: :resource_mismatch}} =
             OAuth.authorize(oauth, @resource)
  end

  test "rejects resource identifiers containing a query instead of silently changing them" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end
    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    assert {:error, %Error{stage: :configuration, reason: :resource_query_forbidden}} =
             OAuth.authorize(oauth, @resource <> "?tenant=other")
  end

  test "requires HTTPS for an explicitly configured authorization server" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end

    assert {:error, %Error{stage: :configuration, reason: :https_required}} =
             Task.async(fn ->
               Process.flag(:trap_exit, true)

               OAuth.start_link(
                 oauth_opts(requester,
                   authorization_server: "http://127.0.0.1:8766/tenant"
                 )
               )
             end)
             |> Task.await()
  end

  test "requires HTTPS for the issuer and every authorization-server endpoint" do
    Enum.each(
      [
        {"issuer", "http://127.0.0.1:8766/tenant"},
        {"authorization_endpoint", "http://127.0.0.1:8766/authorize"},
        {"token_endpoint", "http://127.0.0.1:8766/token"},
        {"registration_endpoint", "http://127.0.0.1:8766/register"}
      ],
      fn {field, insecure_url} ->
        requester = fn
          :get, @resource_metadata, _opts ->
            protected_resource_response()

          :get, @server_metadata, _opts ->
            authorization_server_response(%{field => insecure_url})
        end

        assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
        result = OAuth.authorize(oauth, @resource)

        assert match?(
                 {:error,
                  %Error{
                    stage: :authorization_server_discovery,
                    reason: :https_required
                  }},
                 result
               ),
               "#{field} accepted an insecure authorization-server URL: #{inspect(result)}"
      end
    )
  end

  test "requires HTTPS for Client ID Metadata Document identifiers" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{"client_id_metadata_document_supported" => true})
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 registration:
                   {:client_metadata_document, "http://127.0.0.1:8766/oauth/client.json"}
               )
             )

    assert {:error, %Error{stage: :client_registration, reason: :https_required}} =
             OAuth.authorize(oauth, @resource)
  end

  test "allows loopback HTTP for the MCP resource and redirect only" do
    test_pid = self()
    resource = "http://127.0.0.1:8766/mcp"
    resource_metadata = "http://127.0.0.1:8766/.well-known/oauth-protected-resource/mcp"

    requester = fn
      :get, ^resource_metadata, _opts ->
        json_response(%{
          "resource" => resource,
          "authorization_servers" => [@issuer],
          "scopes_supported" => ["files:read"]
        })

      :get, @server_metadata, _opts ->
        authorization_server_response()

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:loopback_resource_token_form, Map.new(opts[:form])})
        token_response()
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, resource)
    assert_receive {:loopback_resource_token_form, %{"resource" => ^resource}}
  end

  test "rejects loopback HTTP resource metadata for a remote HTTPS resource" do
    test_pid = self()

    requester = fn method, url, opts ->
      send(test_pid, {:unexpected_oauth_request, method, url, opts})
      oauth_response(method, url, opts)
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    headers = [
      {"www-authenticate",
       ~s(Bearer resource_metadata="http://127.0.0.1:8766/.well-known/oauth-protected-resource")}
    ]

    assert {:error, %Error{stage: :protected_resource_discovery, reason: :https_required}} =
             OAuth.handle_unauthorized(oauth, @resource, headers)

    refute_receive {:unexpected_oauth_request, _, _, _}
  end

  test "validates RFC 9207 iss exactly before acting on success or error responses" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "authorization_response_iss_parameter_supported" => true
        })

      :post, "https://auth.example.com/token", _opts ->
        send(test_pid, :unexpected_token_exchange)
        token_response()
    end

    responses = [
      fn request, state ->
        {:ok,
         %{
           code: "must-not-be-redeemed",
           state: state,
           redirect_uri: request.redirect_uri,
           iss: "https://AUTH.example.com/tenant"
         }}
      end,
      fn request, state ->
        {:ok,
         %{
           error: "access_denied",
           error_description: "must-not-be-exposed",
           state: state,
           redirect_uri: request.redirect_uri,
           iss: "https://evil.example/tenant"
         }}
      end
    ]

    Enum.each(responses, fn response ->
      handler = fn request ->
        state =
          request.authorization_url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("state")

        response.(request, state)
      end

      assert {:ok, oauth} =
               OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

      assert {:error, %Error{stage: :authorization, reason: :authorization_issuer_mismatch}} =
               OAuth.authorize(oauth, @resource)

      GenServer.stop(oauth)
    end)

    refute_receive :unexpected_token_exchange
  end

  test "requires iss when the authorization server advertises RFC 9207 support" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "authorization_response_iss_parameter_supported" => true
        })
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    assert {:error, %Error{stage: :authorization, reason: :authorization_issuer_required}} =
             OAuth.authorize(oauth, @resource)
  end

  test "reports an authorization error only after a matching error-response issuer" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "authorization_response_iss_parameter_supported" => true
        })
    end

    handler = fn request ->
      state =
        request.authorization_url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("state")

      {:ok,
       request.redirect_uri <>
         "?" <>
         URI.encode_query(%{
           "error" => "access_denied",
           "error_description" => "private detail",
           "iss" => @issuer,
           "state" => state
         })}
    end

    assert {:ok, oauth} =
             OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

    assert {:error, %Error{stage: :authorization, reason: :authorization_server_error} = error} =
             OAuth.authorize(oauth, @resource)

    refute Exception.message(error) =~ "private detail"
  end

  test "validates a present iss even when the metadata flag is absent" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end

    handler = fn request ->
      state =
        request.authorization_url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("state")

      {:ok,
       %{
         code: "must-not-be-redeemed",
         state: state,
         redirect_uri: request.redirect_uri,
         iss: @issuer <> "/"
       }}
    end

    assert {:ok, oauth} =
             OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

    assert {:error, %Error{stage: :authorization, reason: :authorization_issuer_mismatch}} =
             OAuth.authorize(oauth, @resource)
  end

  test "requires authorization metadata issuer to be identical to the advertised issuer" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{"issuer" => @issuer <> "/"})
    end

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

    assert {:error, %Error{stage: :authorization_server_discovery, reason: :issuer_mismatch}} =
             OAuth.authorize(oauth, @resource)
  end

  test "binds pre-registered credentials to their configured authorization server issuer" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end

    assert {:ok, oauth} =
             OAuth.start_link(
               oauth_opts(requester,
                 registration:
                   {:pre_registered,
                    client_id: "bound-client", issuer: "https://other-auth.example.com"}
               )
             )

    assert {:error,
            %Error{
              stage: :client_registration,
              reason: :authorization_server_binding_mismatch
            }} = OAuth.authorize(oauth, @resource)
  end

  test "reuses dynamic registration for the same issuer and sends explicit application_type" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        authorization_server_response(%{
          "registration_endpoint" => "https://auth.example.com/register"
        })

      :post, "https://auth.example.com/register", opts ->
        send(test_pid, {:dynamic_registration, opts[:json]})
        json_response(%{"client_id" => "dynamic-client"})

      :post, "https://auth.example.com/token", _opts ->
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               redirect_uri: "https://client.example.com/callback",
               registration: {:dynamic, %{application_type: "web"}},
               authorization_handler: successful_authorization_handler(),
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

    challenge = [
      {"www-authenticate", ~s(Bearer error="insufficient_scope" scope="files:admin")}
    ]

    assert {:ok, "Bearer access-one"} =
             OAuth.handle_unauthorized(oauth, @resource, challenge)

    assert_receive {:dynamic_registration, %{"application_type" => "web"}}
    refute_receive {:dynamic_registration, _payload}
  end

  test "client credentials uses client_secret_basic without browser or DCR and reacquires on expiry" do
    test_pid = self()

    requester = fn
      :get, @resource_metadata, _opts ->
        send(test_pid, :client_credentials_discovery)
        protected_resource_response()

      :get, @server_metadata, _opts ->
        json_response(%{
          "issuer" => @issuer,
          "token_endpoint" => "https://auth.example.com/token",
          "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
        })

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:client_credentials_token, opts})

        json_response(%{
          "access_token" => "machine-token",
          "token_type" => "Bearer",
          "expires_in" => 1,
          "scope" => "files:read"
        })
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               grant:
                 {:client_credentials,
                  client_id: "machine-client",
                  client_secret: "s3cret",
                  token_endpoint_auth_method: "client_secret_basic",
                  issuer: @issuer},
               requester: requester
             )

    assert {:ok, "Bearer machine-token"} = OAuth.authorize(oauth, @resource)
    assert {:ok, "Bearer machine-token"} = OAuth.authorization_header(oauth, @resource)

    assert_receive {:client_credentials_token, first_opts}
    assert_receive {:client_credentials_token, second_opts}

    for opts <- [first_opts, second_opts] do
      assert Map.new(opts[:form]) == %{
               "grant_type" => "client_credentials",
               "resource" => @resource,
               "scope" => "files:read"
             }

      assert [{"authorization", "Basic " <> encoded}] = opts[:headers]
      assert Base.decode64!(encoded) == "machine-client:s3cret"
    end

    assert_receive :client_credentials_discovery
    assert_receive :client_credentials_discovery
  end

  test "client credentials delegates private_key_jwt creation and validates AS algorithms" do
    test_pid = self()

    assertion_provider = fn request ->
      send(test_pid, {:client_assertion_request, request})
      {:ok, "signed-client-assertion"}
    end

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        json_response(%{
          "issuer" => @issuer,
          "token_endpoint" => "https://auth.example.com/token",
          "token_endpoint_auth_methods_supported" => ["private_key_jwt"],
          "token_endpoint_auth_signing_alg_values_supported" => ["ES256"]
        })

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:private_key_token, Map.new(opts[:form])})
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               grant:
                 {:client_credentials,
                  client_id: "machine-client",
                  token_endpoint_auth_method: "private_key_jwt",
                  assertion_provider: assertion_provider},
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

    assert_receive {:client_assertion_request, request}
    assert request.client_id == "machine-client"
    assert request.token_endpoint == "https://auth.example.com/token"
    assert request.authorization_server == @issuer
    assert request.signing_algorithms == ["ES256"]
    assert request.grant_type == "client_credentials"

    assert_receive {:private_key_token, form}
    assert form["client_assertion"] == "signed-client-assertion"

    assert form["client_assertion_type"] ==
             "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

    refute Map.has_key?(form, "client_id")
  end

  test "enterprise managed authorization performs the ID-JAG and resource token exchanges" do
    test_pid = self()

    provider = fn request ->
      send(test_pid, {:enterprise_request, request})

      {:ok,
       %{
         token_endpoint: "https://idp.example.com/token",
         subject_token: "stored-id-token",
         subject_token_type: "urn:ietf:params:oauth:token-type:id_token",
         headers: [{"authorization", "Basic idp-client"}],
         form: [{"client_id", "enterprise-client"}]
       }}
    end

    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        json_response(%{
          "issuer" => @issuer,
          "token_endpoint" => "https://auth.example.com/token"
        })

      :post, "https://idp.example.com/token", opts ->
        send(test_pid, {:idp_exchange, opts})

        json_response(%{
          "issued_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
          "access_token" => "signed-id-jag",
          "token_type" => "N_A",
          "expires_in" => 300
        })

      :post, "https://auth.example.com/token", opts ->
        send(test_pid, {:resource_exchange, opts})
        token_response()
    end

    assert {:ok, oauth} =
             OAuth.start_link(
               grant:
                 {:enterprise_managed,
                  registration:
                    {:pre_registered,
                     client_id: "mcp-client",
                     client_secret: "resource-secret",
                     token_endpoint_auth_method: "client_secret_basic",
                     issuer: @issuer},
                  provider: provider},
               requester: requester
             )

    assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

    assert_receive {:enterprise_request, request}
    assert request.resource == @resource
    assert request.authorization_server == @issuer
    assert request.scopes == ["files:read"]

    assert_receive {:idp_exchange, idp_opts}
    idp_form = Map.new(idp_opts[:form])
    assert idp_form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange"
    assert idp_form["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag"
    assert idp_form["audience"] == @issuer
    assert idp_form["resource"] == @resource
    assert idp_form["subject_token"] == "stored-id-token"
    assert idp_form["subject_token_type"] == "urn:ietf:params:oauth:token-type:id_token"
    assert idp_form["scope"] == "files:read"
    assert idp_form["client_id"] == "enterprise-client"
    assert idp_opts[:headers] == [{"authorization", "Basic idp-client"}]

    assert_receive {:resource_exchange, resource_opts}
    resource_form = Map.new(resource_opts[:form])
    assert resource_form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert resource_form["assertion"] == "signed-id-jag"
    assert resource_form["client_id"] == "mcp-client"
    assert resource_form["resource"] == @resource
    assert [{"authorization", "Basic " <> _encoded}] = resource_opts[:headers]
  end

  test "rejects EMA when authorization metadata explicitly advertises other grant profiles" do
    requester = fn
      :get, @resource_metadata, _opts ->
        protected_resource_response()

      :get, @server_metadata, _opts ->
        json_response(%{
          "issuer" => @issuer,
          "token_endpoint" => "https://auth.example.com/token",
          "authorization_grant_profiles_supported" => ["urn:example:other-profile"]
        })
    end

    provider = fn _request -> {:error, :must_not_run} end

    assert {:ok, oauth} =
             OAuth.start_link(
               grant:
                 {:enterprise_managed,
                  registration: {:pre_registered, client_id: "mcp-client"}, provider: provider},
               requester: requester
             )

    assert {:error,
            %Error{
              stage: :authorization_server_discovery,
              reason: :enterprise_managed_grant_not_supported
            }} = OAuth.authorize(oauth, @resource)
  end

  describe "single-flight coordinator" do
    test "a header request joins a pending authorization and the handler runs once" do
      requester = fn method, url, opts -> oauth_response(method, url, opts) end
      handler = blocking_authorization_handler(self(), fn _request -> true end)

      assert {:ok, oauth} =
               OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

      authorizing = Task.async(fn -> OAuth.authorize(oauth, @resource) end)
      assert_receive {:authorizing, handler_pid, _request}

      joining = Task.async(fn -> OAuth.authorization_header(oauth, @resource) end)
      refute Task.yield(joining, 100)
      send(handler_pid, :continue)

      assert {:ok, "Bearer access-one"} = Task.await(authorizing)
      assert {:ok, "Bearer access-one"} = Task.await(joining)
      refute_received {:authorizing, _pid, _request}
    end

    test "other resources answer while a flow is blocked in the host handler" do
      other = "https://mcp.example.com/other/mcp"
      other_metadata = "https://mcp.example.com/.well-known/oauth-protected-resource/other/mcp"

      requester = fn
        :get, ^other_metadata, _opts ->
          json_response(%{"resource" => other, "authorization_servers" => [@issuer]})

        method, url, opts ->
          oauth_response(method, url, opts)
      end

      handler = blocking_authorization_handler(self(), &(&1.resource == other))

      assert {:ok, oauth} =
               OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

      assert {:ok, "Bearer access-one"} = OAuth.authorize(oauth, @resource)

      blocked = Task.async(fn -> OAuth.authorize(oauth, other) end)
      assert_receive {:authorizing, handler_pid, %{resource: ^other}}

      header = Task.async(fn -> OAuth.authorization_header(oauth, @resource) end)
      assert {:ok, {:ok, "Bearer access-one"}} = Task.yield(header, 1_000)

      clear = Task.async(fn -> OAuth.clear(oauth, @resource) end)
      assert {:ok, :ok} = Task.yield(clear, 1_000)
      assert :none = OAuth.authorization_header(oauth, @resource)

      send(handler_pid, :continue)
      assert {:ok, "Bearer access-one"} = Task.await(blocked)
      assert {:ok, "Bearer access-one"} = OAuth.authorization_header(oauth, other)
    end

    test "clear cancels a pending flow, which never stores its credential" do
      requester = fn method, url, opts -> oauth_response(method, url, opts) end
      handler = blocking_authorization_handler(self(), fn _request -> true end)

      assert {:ok, oauth} =
               OAuth.start_link(
                 oauth_opts(requester,
                   authorization_handler: handler,
                   credential_listener: self()
                 )
               )

      authorizing = Task.async(fn -> OAuth.authorize(oauth, @resource) end)
      assert_receive {:authorizing, handler_pid, _request}
      handler_ref = Process.monitor(handler_pid)

      clear = Task.async(fn -> OAuth.clear(oauth, @resource) end)
      assert {:ok, :ok} = Task.yield(clear, 1_000)
      assert {:error, %Error{stage: :authorization, reason: :cleared}} = Task.await(authorizing)
      assert_receive {:DOWN, ^handler_ref, :process, ^handler_pid, _reason}

      assert :none = OAuth.authorization_header(oauth, @resource)
      refute_received :oauth_credentials_refreshed
    end

    @tag :capture_log
    test "a crashed flow answers its callers with an error and the coordinator survives" do
      requester = fn
        :post, "https://auth.example.com/token", _opts -> raise "token endpoint exploded"
        method, url, opts -> oauth_response(method, url, opts)
      end

      assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))

      assert {:error, %Error{stage: :authorization, reason: :flow_crashed}} =
               OAuth.authorize(oauth, @resource)

      assert Process.alive?(oauth)
      assert :none = OAuth.authorization_header(oauth, @resource)
    end

    test "a caller that times out leaves the flow running to store its result" do
      requester = fn method, url, opts -> oauth_response(method, url, opts) end
      handler = blocking_authorization_handler(self(), fn _request -> true end)

      assert {:ok, oauth} =
               OAuth.start_link(oauth_opts(requester, authorization_handler: handler))

      authorizing = Task.async(fn -> OAuth.authorize(oauth, @resource, timeout_ms: 100) end)
      assert_receive {:authorizing, handler_pid, _request}

      assert {:error, %Error{stage: :authorization, reason: :timeout}} =
               Task.await(authorizing, 1_000)

      assert {:error, %Error{stage: :authorization, reason: :timeout}} =
               OAuth.authorization_header(oauth, @resource, 50)

      send(handler_pid, :continue)
      assert {:ok, "Bearer access-one"} = OAuth.authorization_header(oauth, @resource)
      refute_received {:authorizing, _pid, _request}
    end

    test "an authorization request waits out a pending refresh and authorizes if it fails" do
      test_pid = self()
      authorizations = :counters.new(1, [])

      requester = fn
        :post, "https://auth.example.com/token", opts ->
          case Map.new(opts[:form])["grant_type"] do
            "refresh_token" ->
              send(test_pid, {:refreshing, self()})
              receive do: (:continue -> {:ok, 400, [], ""})

            "authorization_code" ->
              :counters.add(authorizations, 1, 1)

              json_response(%{
                "access_token" => "access-#{:counters.get(authorizations, 1)}",
                "token_type" => "Bearer",
                "refresh_token" => "refresh-one",
                "expires_in" => 1
              })
          end

        method, url, opts ->
          oauth_response(method, url, opts)
      end

      assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
      assert {:ok, "Bearer access-1"} = OAuth.authorize(oauth, @resource)

      header = Task.async(fn -> OAuth.authorization_header(oauth, @resource, :infinity) end)
      assert_receive {:refreshing, refresher}

      unauthorized =
        Task.async(fn -> OAuth.handle_unauthorized(oauth, @resource, [], attempt: 2) end)

      refute Task.yield(unauthorized, 50)
      send(refresher, :continue)

      assert {:error, %Error{stage: :token_refresh, reason: {:http_status, 400}}} =
               Task.await(header)

      assert {:ok, "Bearer access-2"} = Task.await(unauthorized)
    end

    test "a connected client stops promptly while its authorization is pending" do
      %{port: port} = serve!(ChallengePlug)
      resource = "http://127.0.0.1:#{port}/mcp"
      metadata = "http://127.0.0.1:#{port}/.well-known/oauth-protected-resource/mcp"

      requester = fn
        :get, ^metadata, _opts ->
          json_response(%{"resource" => resource, "authorization_servers" => [@issuer]})

        method, url, opts ->
          oauth_response(method, url, opts)
      end

      handler = blocking_authorization_handler(self(), fn _request -> true end)

      %Client{pid: client_pid} =
        client =
        Client.connect!(resource,
          protocol_version: "2025-11-25",
          auto_initialize: false,
          oauth: oauth_opts(requester, authorization_handler: handler)
        )

      spawn(fn -> Client.initialize(client) end)
      assert_receive {:authorizing, handler_pid, _request}, 2_000
      handler_ref = Process.monitor(handler_pid)
      client_ref = Process.monitor(client_pid)

      assert :ok = Client.disconnect(client)
      assert_receive {:DOWN, ^client_ref, :process, ^client_pid, _reason}, 2_000
      assert_receive {:DOWN, ^handler_ref, :process, ^handler_pid, _reason}, 2_000
    end
  end

  test "the connected client validates oauth options before it starts" do
    requester = fn method, url, opts -> oauth_response(method, url, opts) end
    insecure = oauth_opts(requester, authorization_server: "http://127.0.0.1:8766/tenant")

    assert_raise ArgumentError, "OAuth configuration failed: https required", fn ->
      Client.connect("https://mcp.example.com/mcp", oauth: insecure)
    end

    error =
      assert_raise ArgumentError, fn ->
        Client.connect("https://mcp.example.com/mcp",
          oauth: oauth_opts(requester, client_secret: "s3cret")
        )
      end

    assert error.message =~ "unknown keys [:client_secret]"
    refute error.message =~ "s3cret"
  end

  test "tagged noninteractive grants declare their matching MCP extension" do
    client =
      connect!("https://mcp.example.com/mcp",
        auto_initialize: false,
        oauth: [
          grant:
            {:client_credentials,
             client_id: "service-client",
             client_secret: "secret",
             token_endpoint_auth_method: "client_secret_basic"}
        ]
      )

    assert ClientProbe.extensions(client) == %{
             Extensions.oauth_client_credentials() => %{}
           }
  end

  defp oauth_opts(requester, overrides \\ []) do
    Keyword.merge(
      [
        redirect_uri: "http://127.0.0.1:8765/callback",
        registration: {:pre_registered, client_id: "test-client"},
        authorization_handler: successful_authorization_handler(),
        requester: requester
      ],
      overrides
    )
  end

  defp successful_authorization_handler do
    fn request ->
      state =
        URI.parse(request.authorization_url).query |> URI.decode_query() |> Map.fetch!("state")

      {:ok,
       %{
         code: "authorization-code",
         state: state,
         redirect_uri: request.redirect_uri
       }}
    end
  end

  # Succeeds like `successful_authorization_handler/0`, but first blocks the
  # requests `block?` selects until the test sends `:continue`.
  defp blocking_authorization_handler(test_pid, block?) do
    fn request ->
      if block?.(request) do
        send(test_pid, {:authorizing, self(), request})
        receive do: (:continue -> :ok)
      end

      successful_authorization_handler().(request)
    end
  end

  defp oauth_response(:get, @resource_metadata, _opts), do: protected_resource_response()

  defp oauth_response(:get, @server_metadata, _opts),
    do: authorization_server_response()

  defp oauth_response(:post, "https://auth.example.com/token", _opts), do: token_response()

  defp protected_resource_response do
    json_response(%{
      "resource" => @resource,
      "authorization_servers" => [@issuer],
      "scopes_supported" => ["files:read"]
    })
  end

  defp authorization_server_response(extra \\ %{}) do
    Map.merge(
      %{
        "issuer" => @issuer,
        "authorization_endpoint" => "https://auth.example.com/authorize",
        "token_endpoint" => "https://auth.example.com/token",
        "code_challenge_methods_supported" => ["S256"]
      },
      extra
    )
    |> json_response()
  end

  defp token_response do
    json_response(%{
      "access_token" => "access-one",
      "token_type" => "Bearer",
      "refresh_token" => "refresh-one",
      "expires_in" => 3600,
      "scope" => "files:read files:write"
    })
  end

  defp json_response(document) do
    {:ok, 200, [{"content-type", "application/json; charset=utf-8"}], JSON.encode!(document)}
  end
end
