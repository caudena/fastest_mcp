defmodule FastestMCP.ClientOAuthTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.OAuth.Error

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

    assert {:ok, oauth} = OAuth.start_link(oauth_opts(requester))
    assert {:ok, "Bearer short-lived"} = OAuth.authorize(oauth, @resource)

    assert_receive {:oauth_http, :post, "https://auth.example.com/token", authorization_opts}
    assert Map.new(authorization_opts[:form])["grant_type"] == "authorization_code"

    assert {:ok, "Bearer refreshed"} = OAuth.authorization_header(oauth, @resource)

    assert_receive {:oauth_http, :post, "https://auth.example.com/token", refresh_opts}
    assert Map.new(refresh_opts[:form])["grant_type"] == "refresh_token"
    assert {:ok, "Bearer refreshed"} = OAuth.authorization_header(oauth, @resource)
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
                      "redirect_uris" => ["http://localhost:8765/callback"]
                    }}

    assert_receive {:token_form, %{"client_id" => "dynamic-client"}}
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
