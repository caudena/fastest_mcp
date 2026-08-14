defmodule FastestMCP.ProtocolVersionFoundationTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Schema
  alias FastestMCP.Transport.Request

  @modern_version "2026-07-28"
  @legacy_version "2025-11-25"

  test "publishes supported versions newest first and derives implementation profiles" do
    assert Protocol.supported_versions() == [@modern_version, @legacy_version]
    assert Protocol.current_version() == @modern_version
    assert FastestMCP.current_protocol_version() == @modern_version
    assert FastestMCP.supported_protocol_versions() == [@modern_version, @legacy_version]

    assert Protocol.supported_version?(@modern_version)
    assert Protocol.supported_version?(@legacy_version)
    refute Protocol.supported_version?("2025-03-26")
    refute Protocol.supported_version?(nil)

    assert Protocol.profile(@modern_version) == :modern
    assert Protocol.profile(@legacy_version) == :legacy
    assert Protocol.profile("2099-01-01") == :unsupported
    assert Protocol.profile(nil) == :unsupported
  end

  test "profile! returns supported profiles and raises for unsupported versions" do
    assert Protocol.profile!(@modern_version) == :modern
    assert Protocol.profile!(@legacy_version) == :legacy

    assert_raise ArgumentError, ~r/unsupported MCP protocol version "2099-01-01"/, fn ->
      Protocol.profile!("2099-01-01")
    end

    assert_raise ArgumentError, ~r/unsupported MCP protocol version nil/, fn ->
      Protocol.profile!(nil)
    end
  end

  test "transport requests carry the selected protocol version without storing a profile" do
    request = %Request{method: "tools/list", protocol_version: @modern_version}
    fields = request |> Map.from_struct() |> Map.keys()

    assert request.protocol_version == @modern_version
    assert :protocol_version in fields
    refute :profile in fields
    refute :era in fields
  end

  test "modern reserved metadata has exact key ownership and basic value shapes" do
    meta = modern_request_meta()

    assert {:ok, ^meta} = Meta.validate(meta, source: :protocol)
    assert {:ok, ^meta} = Meta.validate(meta, source: :peer)
    assert {:error, _reason} = Meta.validate(meta, source: :application)

    assert {:ok, _value} =
             Meta.validate(
               %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "schema-server",
                   "version" => "1.0.0"
                 },
                 "io.modelcontextprotocol/subscriptionId" => 7
               },
               source: :protocol
             )

    assert {:error, _reason} =
             Meta.validate(
               %{"io.modelcontextprotocol/protocolVersion" => 20_260_728},
               source: :protocol
             )

    assert {:error, _reason} =
             Meta.validate(
               %{"io.modelcontextprotocol/clientInfo" => %{"name" => "missing-version"}},
               source: :peer
             )

    assert {:error, _reason} =
             Meta.validate(
               %{"io.modelcontextprotocol/logLevel" => "verbose"},
               source: :protocol
             )
  end

  test "versioned schemas select modern stateless methods and preserve legacy methods" do
    discover = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{"_meta" => modern_request_meta()}
    }

    assert {:ok, ^discover} =
             Schema.validate_protocol(
               @modern_version,
               :client_to_server,
               :request,
               "server/discover",
               discover
             )

    assert Schema.protocol_supported?(
             @modern_version,
             :client_to_server,
             :request,
             "subscriptions/listen"
           )

    refute Schema.protocol_supported?(
             @modern_version,
             :client_to_server,
             :request,
             "initialize"
           )

    assert Schema.protocol_supported?(
             @modern_version,
             :server_to_client,
             :task_response,
             "tools/call"
           )

    assert Schema.protocol_supported?(
             @legacy_version,
             :client_to_server,
             :request,
             "initialize"
           )

    refute Schema.protocol_supported?(
             @legacy_version,
             :client_to_server,
             :request,
             "server/discover"
           )

    assert {:error, error} =
             Schema.compile_protocol(
               "2099-01-01",
               :client_to_server,
               :request,
               "tools/list"
             )

    assert error.message =~ "unsupported MCP protocol version"

    assert {:error, wrong_type} =
             Schema.compile_protocol(
               nil,
               :client_to_server,
               :request,
               "tools/list"
             )

    assert wrong_type.message == "protocol version must be a string"

    assert {:error, unknown_with_invalid_definition} =
             Schema.compile_protocol_definition("2099-01-01", nil)

    assert unknown_with_invalid_definition.message =~ "unsupported MCP protocol version"
  end

  test "modern request metadata, result envelopes, and protocol errors validate exactly" do
    meta = modern_request_meta()

    assert {:ok, ^meta} =
             Schema.validate_protocol(
               @modern_version,
               :client_to_server,
               :request_meta,
               meta
             )

    assert {:error, _error} =
             Schema.validate_protocol(
               @modern_version,
               :client_to_server,
               :request_meta,
               Map.delete(meta, "io.modelcontextprotocol/clientCapabilities")
             )

    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => [@modern_version, @legacy_version],
        "capabilities" => %{},
        "ttlMs" => 60_000,
        "cacheScope" => "public"
      }
    }

    assert {:ok, ^response} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :response,
               "server/discover",
               response
             )

    assert {:error, _error} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :response,
               "server/discover",
               update_in(response, ["result"], &Map.delete(&1, "resultType"))
             )

    unsupported_version = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{
        "code" => -32_022,
        "message" => "Unsupported protocol version",
        "data" => %{
          "requested" => "2099-01-01",
          "supported" => [@modern_version, @legacy_version]
        }
      }
    }

    assert {:ok, ^unsupported_version} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :unsupported_protocol_version_error,
               unsupported_version
             )

    assert {:error, _error} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :unsupported_protocol_version_error,
               put_in(unsupported_version, ["error", "code"], -32_020)
             )
  end

  test "modern common metadata and error definitions retain their tagged constraints" do
    assert {:ok, %{}} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :notification_meta,
               %{}
             )

    assert {:ok, %{"io.modelcontextprotocol/subscriptionId" => "stream-1"}} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :subscriptions_listen_result_meta,
               %{"io.modelcontextprotocol/subscriptionId" => "stream-1"}
             )

    assert {:error, _error} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :subscriptions_listen_result_meta,
               %{}
             )

    for {selector, code} <- [
          parse_error: -32_700,
          invalid_request_error: -32_600,
          method_not_found_error: -32_601,
          invalid_params_error: -32_602,
          internal_error: -32_603
        ] do
      error = %{"code" => code, "message" => "Protocol error"}

      assert {:ok, ^error} =
               Schema.validate_protocol(
                 @modern_version,
                 :server_to_client,
                 selector,
                 error
               )

      assert {:error, _error} =
               Schema.validate_protocol(
                 @modern_version,
                 :server_to_client,
                 selector,
                 %{error | "code" => code - 1}
               )
    end

    header_mismatch = protocol_error_response(-32_020)

    assert {:ok, ^header_mismatch} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :header_mismatch_error,
               header_mismatch
             )

    missing_capability =
      protocol_error_response(-32_021, %{"requiredCapabilities" => %{"roots" => %{}}})

    assert {:ok, ^missing_capability} =
             Schema.validate_protocol(
               @modern_version,
               :server_to_client,
               :missing_required_client_capability_error,
               missing_capability
             )
  end

  test "protocol schema compilation caches independently by version" do
    assert {:ok, modern_first} =
             Schema.compile_protocol_definition(@modern_version, "CallToolResult")

    assert {:ok, modern_second} =
             Schema.compile_protocol_definition(@modern_version, "CallToolResult")

    assert {:ok, legacy} =
             Schema.compile_protocol_definition(@legacy_version, "CallToolResult")

    assert modern_first === modern_second

    result = %{
      "content" => [],
      "resultType" => "complete",
      "structuredContent" => "scalar output"
    }

    assert {:ok, ^result} = Schema.validate(modern_first, result)
    assert {:error, _error} = Schema.validate(legacy, result)

    assert {:ok, latest_discover} = Schema.compile_protocol_definition("DiscoverRequest")

    assert {:ok, explicit_discover} =
             Schema.compile_protocol_definition(@modern_version, "DiscoverRequest")

    assert latest_discover === explicit_discover

    assert {:error, legacy_error} =
             Schema.compile_protocol_definition(@legacy_version, "DiscoverRequest")

    assert legacy_error.message =~ "unknown MCP protocol schema definition"
  end

  defp modern_request_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "schema-client",
        "version" => "1.0.0"
      }
    }
  end

  defp protocol_error_response(code, data \\ nil) do
    error = %{"code" => code, "message" => "Protocol error"}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
  end
end
