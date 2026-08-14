defmodule FastestMCP.ContextAccessTokenTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Context

  test "access_token prefers the live request bearer token over cached auth state" do
    context = %Context{
      server_name: "context-access-token-request-wins",
      session_id: "session-1",
      request_id: "req-1",
      transport: :test,
      request_metadata: %{
        headers: %{"authorization" => "Bearer fresh-token"}
      },
      auth: %{token: "stale-token"}
    }

    assert Context.access_token(context) == "fresh-token"
  end

  test "access_token falls back to auth state when request metadata has no bearer token" do
    context = %Context{
      server_name: "context-access-token-auth-fallback",
      session_id: "session-2",
      request_id: "req-2",
      transport: :test,
      request_metadata: %{headers: %{"authorization" => "Basic abc123"}},
      auth: %{token: "cached-token"}
    }

    assert Context.access_token(context) == "cached-token"
  end

  test "access_token supports string-keyed auth maps and atom-keyed header maps" do
    context = %Context{
      server_name: "context-access-token-mixed-keys",
      session_id: "session-3",
      request_id: "req-3",
      transport: :test,
      request_metadata: %{headers: %{authorization: "Bearer mixed-token"}},
      auth: %{"token" => "cached-token"}
    }

    assert Context.access_token(context) == "mixed-token"
  end

  test "access_token returns nil when there is no request or cached token" do
    context = %Context{
      server_name: "context-access-token-none",
      session_id: "session-4",
      request_id: "req-4",
      transport: :test
    }

    assert Context.access_token(context) == nil
  end

  test "request authorization is private to the live request and cleared for background work" do
    secret = "Bearer private-transport-token"

    assert {:ok, context} =
             Context.build("context-private-authorization",
               transport: :streamable_http,
               state_scope: :request,
               request_metadata: %{
                 headers: %{"authorization" => secret, "x-demo" => "1"},
                 authorization: secret
               }
             )

    assert Context.transport_authorization(context) == secret
    assert Context.access_token(context) == "private-transport-token"
    assert context.request_metadata.headers == %{"x-demo" => "1"}
    refute inspect(context) =~ "private-transport-token"
    refute inspect(Context.request_context(context)) =~ "private-transport-token"
    refute inspect(Context.http_headers(context, include_all: true)) =~ "private-transport-token"

    background = Context.for_background_task(context, "task-1")
    assert Context.transport_authorization(background) == nil
    refute inspect(background) =~ "private-transport-token"
  end

  test "context inspection excludes credential-bearing custom auth state" do
    context = %Context{
      server_name: "context-private-auth-inspect",
      request_id: "req-private-auth",
      auth: %{token: "custom-auth-secret", tenant: "acme"}
    }

    assert Context.access_token(context) == "custom-auth-secret"
    refute inspect(context) =~ "custom-auth-secret"
  end
end
