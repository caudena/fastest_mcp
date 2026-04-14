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
end
