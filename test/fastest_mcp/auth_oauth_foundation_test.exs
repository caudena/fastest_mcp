defmodule FastestMCP.AuthOAuthFoundationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.AssentFlow

  defmodule FakeAssentStrategy do
    def authorize_url(config) do
      {:ok,
       %{
         url: "https://auth.example.com/authorize",
         session_params: %{
           "state" => "abc123",
           "jwt_adapter" => inspect(config[:jwt_adapter]),
           "authorization_params" => Enum.into(config[:authorization_params] || [], %{})
         }
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         user: %{"sub" => "user-123"},
         token: %{"access_token" => params["code"]},
         session_params: config[:session_params]
       }}
    end
  end

  test "assent flow defaults the JOSE jwt adapter and passes session params through callback" do
    flow =
      AssentFlow.new(FakeAssentStrategy,
        client_id: "client-id",
        client_secret: "client-secret",
        redirect_uri: "https://app.example.com/callback"
      )

    assert {:ok, %{url: "https://auth.example.com/authorize", session_params: session_params}} =
             AssentFlow.authorize_url(flow, prompt: "consent")

    assert session_params["jwt_adapter"] == inspect(Assent.JWTAdapter.JOSE)
    assert session_params["authorization_params"] == %{prompt: "consent"}

    assert {:ok,
            %{
              user: %{"sub" => "user-123"},
              token: %{"access_token" => "code-123"},
              session_params: %{"state" => "abc123"}
            }} =
             AssentFlow.callback(flow, %{"code" => "code-123"}, %{"state" => "abc123"})
  end

  test "assent flow rejects invalid strategy modules" do
    assert_raise ArgumentError, ~r/must export authorize_url\/1 and callback\/2/, fn ->
      AssentFlow.new(String)
    end
  end
end
