defmodule FastestMCP.ClientOAuthCacheInvalidationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Test.ClientProbe

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Client.OAuth

  defmodule AuthenticatedCatalogPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      state = Keyword.fetch!(opts, :state)
      credential = bearer_credential(conn)

      case request do
        %{"id" => id, "method" => "server/discover"} ->
          reply(conn, id, %{
            "resultType" => "complete",
            "supportedVersions" => ["2026-07-28"],
            "capabilities" => %{"tools" => %{}, "resources" => %{}},
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => %{
              "io.modelcontextprotocol/serverInfo" => %{
                "name" => "oauth-cache-test",
                "version" => "1.0.0"
              }
            }
          })

        %{"id" => id, "method" => "tools/list"} ->
          bump(state, :tool_lists)

          reply(conn, id, %{
            "resultType" => "complete",
            "tools" => [
              %{
                "name" => tool_name(credential),
                "inputSchema" => %{"type" => "object"}
              }
            ],
            "ttlMs" => 60_000,
            "cacheScope" => "private"
          })

        %{"id" => id, "method" => "tools/call", "params" => %{"name" => name}} ->
          Agent.update(state, &Map.put(&1, :last_tool_credential, credential))
          result = %{"tool" => name}

          reply(conn, id, %{
            "resultType" => "complete",
            "content" => [%{"type" => "text", "text" => JSON.encode!(result)}],
            "structuredContent" => result
          })

        %{"id" => id, "method" => "resources/read", "params" => %{"uri" => uri}} ->
          bump(state, :resource_reads)
          result = %{"credential" => credential}

          reply(conn, id, %{
            "resultType" => "complete",
            "contents" => [
              %{
                "uri" => uri,
                "mimeType" => "application/json",
                "text" => JSON.encode!(result)
              }
            ],
            "ttlMs" => 60_000,
            "cacheScope" => "private"
          })
      end
    end

    defp tool_name("token-one"), do: "first_tool"
    defp tool_name("token-two"), do: "second_tool"
    defp tool_name(_credential), do: "anonymous_tool"

    defp bearer_credential(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> credential] -> credential
        _headers -> nil
      end
    end

    defp bump(state, key) do
      Agent.update(state, &Map.update(&1, key, 1, fn count -> count + 1 end))
    end

    defp reply(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  test "proactive OAuth reacquisition invalidates response and descriptor caches" do
    state = start_supervised!({Agent, fn -> %{token_requests: 0} end})

    %{port: port} = serve!({AuthenticatedCatalogPlug, state: state})
    resource = "http://127.0.0.1:#{port}/mcp"
    issuer = "https://auth.example.com"
    token_endpoint = issuer <> "/token"

    requester = fn
      :get, url, _opts ->
        if String.contains?(url, "oauth-protected-resource") do
          json_response(%{
            "resource" => resource,
            "authorization_servers" => [issuer],
            "scopes_supported" => ["files:read"]
          })
        else
          json_response(%{
            "issuer" => issuer,
            "token_endpoint" => token_endpoint,
            "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
          })
        end

      :post, ^token_endpoint, _opts ->
        request_number =
          Agent.get_and_update(state, fn current ->
            next = current.token_requests + 1
            {next, %{current | token_requests: next}}
          end)

        {credential, expires_in} =
          if request_number == 1, do: {"token-one", 33}, else: {"token-two", 3_600}

        json_response(%{
          "access_token" => credential,
          "token_type" => "Bearer",
          "expires_in" => expires_in,
          "scope" => "files:read"
        })
    end

    client =
      connect!(resource,
        protocol_version: "2026-07-28",
        response_cache: true,
        oauth: [
          grant:
            {:client_credentials,
             client_id: "machine-client",
             client_secret: "secret",
             token_endpoint_auth_method: "client_secret_basic",
             issuer: issuer},
          requester: requester
        ]
      )

    assert {:ok, "Bearer token-one"} = OAuth.authorize(ClientProbe.oauth_pid(client), resource)
    wait_for_auth_generation(client, 1)

    assert %{structured_content: %{"tool" => "first_tool"}} =
             Client.call_tool!(client, "first_tool", %{})

    assert %{"credential" => "token-one"} = Client.read_resource!(client, "memory://auth")
    assert %{"credential" => "token-one"} = Client.read_resource!(client, "memory://auth")

    assert Agent.get(state, & &1.tool_lists) == 1
    assert Agent.get(state, & &1.resource_reads) == 1

    # token-one enters the proactive refresh window after three seconds.
    Process.sleep(3_100)

    assert %{structured_content: %{"tool" => "first_tool"}} =
             Client.call_tool!(client, "first_tool", %{})

    wait_for_auth_generation(client, 2)

    assert %{structured_content: %{"tool" => "second_tool"}} =
             Client.call_tool!(client, "second_tool", %{})

    assert %{"credential" => "token-two"} = Client.read_resource!(client, "memory://auth")

    snapshot = Agent.get(state, & &1)
    assert snapshot.token_requests == 2
    assert snapshot.last_tool_credential == "token-two"
    assert snapshot.tool_lists == 2
    assert snapshot.resource_reads == 2
  end

  defp wait_for_auth_generation(client, expected),
    do: assert_eventually(fn -> ClientProbe.auth_generation(client) >= expected end)

  defp json_response(document) do
    {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(document)}
  end
end
