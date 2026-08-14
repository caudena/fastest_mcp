defmodule FastestMCP.TestSupport.ConformanceClientHarness do
  @moduledoc false

  alias FastestMCP.Client
  alias FastestMCP.TestSupport.ConformanceOAuthBridge
  alias FastestMCP.TestSupport.PinnedConformanceSSEProxy

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
      "request-metadata" -> run_request_metadata(server_url)
      "elicitation-sep1034-client-defaults" -> run_elicitation_defaults(server_url)
      "sse-retry" -> run_sse_retry(server_url)
      "sep-2322-client-request-state" -> run_mrtr_request_state(server_url)
      "http-standard-headers" -> run_standard_headers(server_url)
      "http-custom-headers" -> run_context_tool_calls(server_url)
      "http-invalid-tool-headers" -> run_invalid_tool_headers(server_url)
      "json-schema-ref-no-deref" -> run_list_tools(server_url, "schema-ref")
      "auth/client-credentials-jwt" -> run_client_credentials(server_url, :jwt)
      "auth/client-credentials-basic" -> run_client_credentials(server_url, :basic)
      "auth/enterprise-managed-authorization" -> run_enterprise_managed(server_url)
      "auth/" <> _rest -> run_oauth(server_url, scenario)
      other -> raise ArgumentError, "unsupported client conformance scenario #{inspect(other)}"
    end
  end

  defp run_initialize(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-initialize"),
        protocol_version: protocol_version!()
      )

    Client.disconnect(client)
  end

  defp run_tools_call(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-tools"),
        protocol_version: protocol_version!()
      )

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

  defp run_request_metadata(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-request-metadata"),
        protocol_version: protocol_version!(),
        roots: [],
        sampling_handler: fn _messages, _params ->
          %{
            "role" => "assistant",
            "model" => "conformance-model",
            "content" => %{"type" => "text", "text" => "ok"}
          }
        end,
        elicitation_handler: fn _message, _params -> {:accept, %{}} end
      )

    try do
      _tools = Client.list_tools(client)
    after
      Client.disconnect(client)
    end
  end

  defp run_elicitation_defaults(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-elicitation-defaults"),
        protocol_version: protocol_version!(),
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
    {server_url, proxy} = maybe_proxy_pinned_legacy_sse(server_url)

    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-sse-retry"),
        protocol_version: protocol_version!(),
        sse_reconnect: [max_attempts: 3, min_retry_ms: 100, max_retry_ms: 10_000]
      )

    try do
      _result = Client.call_tool(client, "test_reconnection", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
      if proxy, do: PinnedConformanceSSEProxy.stop(proxy)
    end
  end

  defp maybe_proxy_pinned_legacy_sse(server_url) do
    if protocol_version!() == "2025-11-25" do
      proxy = PinnedConformanceSSEProxy.start!(server_url)
      {proxy.url, proxy}
    else
      {server_url, nil}
    end
  end

  defp run_mrtr_request_state(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-mrtr-state"),
        protocol_version: protocol_version!(),
        elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
      )

    try do
      _ = Client.list_tools(client)
      _ = Client.call_tool(client, "test_mrtr_unrelated", %{})
      _ = Client.call_tool(client, "test_mrtr_echo_state", %{})
      _ = Client.call_tool(client, "test_mrtr_no_state", %{})
      _ = Client.call_tool(client, "test_mrtr_no_result_type", %{})
    after
      Client.disconnect(client)
    end
  end

  defp run_standard_headers(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-standard-headers"),
        protocol_version: protocol_version!()
      )

    try do
      %{items: [tool | _]} = Client.list_tools(client)
      _ = Client.call_tool(client, tool["name"], %{})

      %{items: [resource | _]} = Client.list_resources(client)
      _ = Client.read_resource(client, resource["uri"])

      %{items: [prompt | _]} = Client.list_prompts(client)
      _ = Client.render_prompt(client, prompt["name"], %{})
    after
      Client.disconnect(client)
    end
  end

  defp run_context_tool_calls(server_url) do
    context = conformance_context!()

    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-custom-headers"),
        protocol_version: protocol_version!()
      )

    try do
      _ = Client.list_tools(client)

      Enum.each(Map.fetch!(context, "toolCalls"), fn %{
                                                       "name" => name,
                                                       "arguments" => arguments
                                                     } ->
        # This scenario intentionally provides an optional null against an
        # advertised boolean schema. Omitting it is the schema-valid form and
        # exercises the same rule: no Mcp-Param header may be emitted.
        arguments = Map.reject(arguments, fn {_name, value} -> is_nil(value) end)
        _ = Client.call_tool(client, name, arguments)
      end)
    after
      Client.disconnect(client)
    end
  end

  defp run_invalid_tool_headers(server_url) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-invalid-tool-headers"),
        protocol_version: protocol_version!()
      )

    try do
      page = Client.list_tools(client)

      unless Enum.any?(page.items, &(&1["name"] == "valid_tool")) do
        raise "client discarded the valid tool while filtering invalid x-mcp-header annotations"
      end

      _ = Client.call_tool(client, "valid_tool", %{"region" => "us-west1"})
    after
      Client.disconnect(client)
    end
  end

  defp run_list_tools(server_url, suffix) do
    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-#{suffix}"),
        protocol_version: protocol_version!()
      )

    try do
      _ = Client.list_tools(client)
    after
      Client.disconnect(client)
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
        protocol_version: protocol_version!(),
        oauth: oauth
      )

    try do
      _tools = Client.list_tools(client, timeout_ms: 15_000)
      _result = Client.call_tool(client, "test-tool", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
    end
  end

  defp run_client_credentials(server_url, method) when method in [:basic, :jwt] do
    context = conformance_context!()

    grant_options =
      case method do
        :basic ->
          [
            client_id: Map.fetch!(context, "client_id"),
            client_secret: Map.fetch!(context, "client_secret"),
            token_endpoint_auth_method: "client_secret_basic"
          ]

        :jwt ->
          private_key_pem = Map.fetch!(context, "private_key_pem")

          [
            client_id: Map.fetch!(context, "client_id"),
            token_endpoint_auth_method: "private_key_jwt",
            assertion_provider: fn request -> sign_client_assertion(request, private_key_pem) end
          ]
      end

    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-client-credentials-#{method}"),
        protocol_version: protocol_version!(),
        extensions: %{"io.modelcontextprotocol/oauth-client-credentials" => %{}},
        oauth: [
          grant: {:client_credentials, grant_options},
          requester: &ConformanceOAuthBridge.request/3,
          max_auth_attempts: 3
        ]
      )

    try do
      _tools = Client.list_tools(client, timeout_ms: 15_000)
      _result = Client.call_tool(client, "test-tool", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
    end
  end

  defp run_enterprise_managed(server_url) do
    context = conformance_context!()

    provider = fn _request ->
      {:ok,
       %{
         token_endpoint:
           context
           |> Map.fetch!("idp_token_endpoint")
           |> ConformanceOAuthBridge.logical_url(),
         subject_token: Map.fetch!(context, "idp_id_token"),
         subject_token_type: "urn:ietf:params:oauth:token-type:id_token"
       }}
    end

    registration =
      {:pre_registered,
       [
         client_id: Map.fetch!(context, "client_id"),
         client_secret: Map.fetch!(context, "client_secret"),
         token_endpoint_auth_method: "client_secret_basic"
       ]}

    client =
      Client.connect!(server_url,
        client_info: client_info("conformance-enterprise-managed"),
        protocol_version: protocol_version!(),
        extensions: %{"io.modelcontextprotocol/enterprise-managed-authorization" => %{}},
        oauth: [
          grant: {:enterprise_managed, registration: registration, provider: provider},
          requester: &ConformanceOAuthBridge.request/3,
          max_auth_attempts: 3
        ]
      )

    try do
      _tools = Client.list_tools(client, timeout_ms: 15_000)
      _result = Client.call_tool(client, "test-tool", %{}, timeout_ms: 15_000)
    after
      Client.disconnect(client)
    end
  end

  defp sign_client_assertion(request, private_key_pem) do
    now = System.system_time(:second)

    # RFC 7523 interoperability targets the token endpoint. The pinned
    # alpha.11 fixture instead verifies its authorization-server base URL, so
    # this test-only assertion carries both accepted JWT audience forms after
    # mapping its logical HTTPS loopback URLs back to physical HTTP.
    audience = [
      ConformanceOAuthBridge.physical_url(request.token_endpoint),
      ConformanceOAuthBridge.physical_url(request.authorization_server)
    ]

    header = %{"alg" => "ES256", "typ" => "JWT"}

    claims = %{
      "iss" => request.client_id,
      "sub" => request.client_id,
      "aud" => audience,
      "iat" => now,
      "exp" => now + 300,
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    signing_input = base64url_json(header) <> "." <> base64url_json(claims)

    with [entry] <- :public_key.pem_decode(private_key_pem),
         private_key <- :public_key.pem_entry_decode(entry),
         signature_der <- :public_key.sign(signing_input, :sha256, private_key),
         {:"ECDSA-Sig-Value", r, s} <-
           :public_key.der_decode(:"ECDSA-Sig-Value", signature_der) do
      signature = fixed_unsigned(r, 32) <> fixed_unsigned(s, 32)
      {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
    else
      _ -> {:error, :invalid_conformance_private_key}
    end
  rescue
    _error -> {:error, :invalid_conformance_private_key}
  end

  defp base64url_json(value) do
    value
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp fixed_unsigned(value, size) do
    encoded = :binary.encode_unsigned(value)
    :binary.copy(<<0>>, size - byte_size(encoded)) <> encoded
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

  defp protocol_version! do
    System.fetch_env!("MCP_CONFORMANCE_PROTOCOL_VERSION")
  end

  defp client_info(name), do: %{"name" => name, "version" => "0.2.0-conformance"}
end

FastestMCP.TestSupport.ConformanceClientHarness.run!()
