defmodule FastestMCP.TestSupport.ConformanceClientHarness do
  @moduledoc false

  alias FastestMCP.Client
  alias FastestMCP.TestSupport.ConformanceClientProtocolProxy
  alias FastestMCP.TestSupport.ConformanceOAuthBridge

  @cimd_client_id "https://conformance-test.local/client-metadata.json"
  @redirect_uri "http://localhost:3000/callback"

  def run! do
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)

    case Application.ensure_all_started(:fastest_mcp) do
      {:ok, _applications} -> :ok
      {:error, reason} -> raise "failed to start FastestMCP: #{inspect(reason)}"
    end

    [server_url] = System.argv()
    scenario = System.fetch_env!("MCP_CONFORMANCE_SCENARIO")

    case scenario do
      "initialize" -> run_initialize(server_url)
      "tools_call" -> run_tools_call(server_url)
      "elicitation-sep1034-client-defaults" -> run_elicitation_defaults(server_url)
      "sse-retry" -> run_sse_retry(server_url)
      "auth/" <> _rest -> run_oauth(server_url, scenario)
      other -> raise ArgumentError, "unsupported client conformance scenario #{inspect(other)}"
    end
  end

  defp run_initialize(server_url) do
    client = Client.connect!(server_url, client_info: client_info("conformance-initialize"))
    Client.disconnect(client)
  end

  defp run_tools_call(server_url) do
    client = Client.connect!(server_url, client_info: client_info("conformance-tools"))

    try do
      page = Client.list_tools(client)

      unless Enum.any?(page.items, &(&1["name"] == "add_numbers")) do
        raise "conformance server did not advertise add_numbers"
      end

      _result = Client.call_tool(client, "add_numbers", %{"a" => 20, "b" => 22})
    after
      Client.disconnect(client)
    end
  end

  defp run_elicitation_defaults(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-elicitation-defaults"),
        elicitation_handler: fn _message, _params -> {:accept, %{}} end,
        session_stream: true
      )

    try do
      page = Client.list_tools(client)

      unless Enum.any?(page.items, &(&1["name"] == "test_client_elicitation_defaults")) do
        raise "conformance server did not advertise the elicitation defaults tool"
      end

      _result =
        Client.call_tool(client, "test_client_elicitation_defaults", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
    end
  end

  defp run_sse_retry(server_url) do
    proxy = ConformanceClientProtocolProxy.start!(server_url)

    try do
      client =
        Client.connect!(proxy.url,
          client_info: client_info("conformance-sse-retry"),
          sse_reconnect: [max_attempts: 3, min_retry_ms: 100, max_retry_ms: 10_000]
        )

      try do
        _result = Client.call_tool(client, "test_reconnection", %{}, timeout_ms: 15_000)
      after
        Client.disconnect(client)
      end
    after
      ConformanceClientProtocolProxy.stop(proxy)
    end
  end

  defp run_oauth(server_url, scenario) do
    oauth =
      [
        redirect_uri: @redirect_uri,
        registration: registration_for(scenario),
        authorization_handler: &ConformanceOAuthBridge.authorize/1,
        requester: &ConformanceOAuthBridge.request/3,
        max_auth_attempts: 3
      ]

    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-oauth"),
        oauth: oauth
      )

    try do
      _tools = Client.list_tools(client, timeout_ms: 15_000)
      _result = Client.call_tool(client, "test-tool", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
    end
  end

  defp registration_for("auth/basic-cimd"),
    do: {:client_metadata_document, @cimd_client_id}

  defp registration_for("auth/pre-registration") do
    context = conformance_context!()

    {:pre_registered,
     [
       client_id: Map.fetch!(context, "client_id"),
       client_secret: Map.fetch!(context, "client_secret"),
       token_endpoint_auth_method: "client_secret_basic"
     ]}
  end

  defp registration_for(_scenario) do
    {:dynamic,
     %{
       client_name: "FastestMCP conformance client",
       redirect_uris: [@redirect_uri],
       grant_types: ["authorization_code", "refresh_token"],
       response_types: ["code"],
       token_endpoint_auth_method: "none"
     }}
  end

  defp conformance_context! do
    System.get_env("MCP_CONFORMANCE_CONTEXT", "{}")
    |> JSON.decode!()
  end

  defp client_info(name), do: %{"name" => name, "version" => "0.2.0-conformance"}
end

FastestMCP.TestSupport.ConformanceClientHarness.run!()
