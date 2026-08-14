defmodule FastestMCP.ActiveServerExtensionsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.ServerExtension
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  @modern_version "2026-07-28"
  @extension_id "com.example/active"

  test "validates extension identity and method ownership at server construction" do
    handler = fn params, _context -> params end

    extension =
      ServerExtension.new(@extension_id,
        methods: [ServerExtension.method("example/run", handler)]
      )

    assert_raise ArgumentError, ~r/both passive and active/, fn ->
      FastestMCP.server("collision",
        extensions: %{@extension_id => %{}},
        active_extensions: [extension]
      )
    end

    assert_raise ArgumentError, ~r/duplicate identifiers/, fn ->
      FastestMCP.server("duplicate-id", active_extensions: [extension, extension])
    end

    other =
      ServerExtension.new("org.example/other",
        methods: [ServerExtension.method("example/run", handler)]
      )

    assert_raise ArgumentError, ~r/method ownership is duplicated/, fn ->
      FastestMCP.server("duplicate-method", active_extensions: [extension, other])
    end

    for method <- ["tools/call", "tasks/update", "sampling/createMessage"] do
      shadow =
        ServerExtension.new(@extension_id,
          methods: [ServerExtension.method(method, handler)]
        )

      assert_raise ArgumentError, ~r/cannot shadow core or built-in methods/, fn ->
        FastestMCP.server("shadow-#{method}", active_extensions: [shadow])
      end
    end

    for identifier <- [Extensions.apps(), Extensions.tasks()] do
      specialized = ServerExtension.new(identifier)

      assert_raise ArgumentError, ~r/specialized implementations/, fn ->
        FastestMCP.server("specialized-#{identifier}", active_extensions: [specialized])
      end
    end
  end

  test "mounted children cannot install active extensions" do
    child =
      FastestMCP.server("active-child",
        active_extensions: [ServerExtension.new(@extension_id)]
      )

    root = FastestMCP.server("active-root")

    assert_raise ArgumentError, ~r/mounted child servers cannot declare active_extensions/, fn ->
      FastestMCP.mount(root, child)
    end
  end

  test "discovery merges active settings without mutating passive extensions" do
    server_name = unique_name("active-discovery")

    server =
      FastestMCP.server(server_name,
        extensions: %{"org.example/passive" => %{enabled: true}},
        active_extensions: [
          ServerExtension.new(@extension_id,
            settings: %{mode: "strict"},
            methods: [ServerExtension.method("example/run", fn params, _context -> params end)]
          )
        ]
      )

    assert server.extensions == %{"org.example/passive" => %{"enabled" => true}}
    assert [%ServerExtension{identifier: @extension_id}] = server.active_extensions

    start_server!(server)

    result = Engine.dispatch!(server_name, modern_request("server/discover", %{}, %{}))

    assert get_in(result, ["capabilities", "extensions"]) == %{
             "org.example/passive" => %{"enabled" => true},
             @extension_id => %{"mode" => "strict"}
           }

    {connection_id, %{"result" => legacy}} = ProtocolTest.initialize_stdio(server_name)
    refute get_in(legacy, ["capabilities", "extensions", @extension_id])

    assert %{"error" => %{"code" => -32_601}} =
             ProtocolTest.stdio_request(
               server_name,
               connection_id,
               2,
               "example/run",
               %{"value" => 1}
             )
  end

  test "negotiated methods use auth, middleware, schemas, cleanup, and modern finalization" do
    server_name = unique_name("active-execution")
    test_pid = self()

    schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer"}},
      "required" => ["value"],
      "additionalProperties" => false
    }

    handler = fn params, context ->
      send(test_pid, {:handler, params, context.authenticated})
      Context.register_cleanup(context, fn -> send(test_pid, :request_cleanup) end)

      %{
        "echo" => params["value"],
        "principal" => context.principal
      }
    end

    extension =
      ServerExtension.new(@extension_id,
        methods: [
          ServerExtension.method("example/run", handler, params_schema: schema)
        ]
      )

    middleware = fn operation, next ->
      send(test_pid, {:middleware, operation.method})
      next.(operation)
    end

    auth = fn _input, _context ->
      {:ok, %{principal: {"https://issuer.example", "user-1"}}}
    end

    server =
      FastestMCP.server(server_name,
        auth: auth,
        middleware: [middleware],
        active_extensions: [extension]
      )

    start_server!(server)

    result =
      Engine.dispatch!(
        server_name,
        modern_request("example/run", %{"value" => 7}, extension_capabilities())
      )

    assert result["echo"] == 7
    assert result["principal"] == {"https://issuer.example", "user-1"}
    assert result["resultType"] == "complete"
    assert get_in(result, ["_meta", "io.modelcontextprotocol/serverInfo", "name"]) == server_name
    refute Map.has_key?(result, "ttlMs")

    assert_receive {:middleware, "example/run"}
    assert_receive {:handler, %{"value" => 7}, true}
    assert_receive :request_cleanup

    error =
      assert_raise Error, fn ->
        Engine.dispatch!(
          server_name,
          modern_request("example/run", %{"value" => "invalid"}, extension_capabilities())
        )
      end

    assert error.code == :invalid_params
    refute_receive {:handler, "invalid", _authenticated}
  end

  test "missing negotiation, notifications, and unknown methods fail before handlers run" do
    server_name = unique_name("active-negotiation")
    test_pid = self()

    handler = fn params, _context ->
      send(test_pid, :called)
      params
    end

    server =
      FastestMCP.server(server_name,
        active_extensions: [
          ServerExtension.new(@extension_id,
            methods: [ServerExtension.method("example/run", handler)]
          )
        ]
      )

    start_server!(server)

    error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, modern_request("example/run", %{"value" => 1}, %{}))
      end

    assert error.code == :missing_required_client_capability

    assert error.details.requiredCapabilities == %{
             extensions: %{@extension_id => %{}}
           }

    notification =
      modern_request("example/run", %{"value" => 1}, extension_capabilities())
      |> Map.put(:request_id, nil)

    notification_error =
      assert_raise Error, fn -> Engine.dispatch!(server_name, notification) end

    assert notification_error.code == :invalid_request

    unknown =
      assert_raise Error, fn ->
        Engine.dispatch!(
          server_name,
          modern_request("example/unknown", %{}, extension_capabilities())
        )
      end

    assert unknown.code == :method_not_found
    refute_receive :called
  end

  test "active method results must remain JSON objects" do
    server_name = unique_name("active-result-shape")

    server =
      FastestMCP.server(server_name,
        active_extensions: [
          ServerExtension.new(@extension_id,
            methods: [
              ServerExtension.method("example/run", fn _params, _context -> "invalid" end)
            ]
          )
        ]
      )

    start_server!(server)

    error =
      assert_raise Error, fn ->
        Engine.dispatch!(
          server_name,
          modern_request("example/run", %{}, extension_capabilities())
        )
      end

    assert error.code == :internal_error
    assert error.message =~ "must return a JSON object"
  end

  test "extension lifespans are namespaced and cleaned up through the runtime" do
    server_name = unique_name("active-lifespan")
    test_pid = self()

    extension =
      ServerExtension.new(@extension_id,
        lifespan: fn _server ->
          {%{"token" => "extension-state"}, fn -> send(test_pid, :lifespan_cleanup) end}
        end,
        methods: [
          ServerExtension.method("example/state", fn _params, context ->
            %{"state" => context.lifespan_context[@extension_id]}
          end)
        ]
      )

    server =
      FastestMCP.server(server_name,
        lifespan: fn _server -> %{"root-state" => true} end,
        active_extensions: [extension]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result =
      Engine.dispatch!(
        server_name,
        modern_request("example/state", %{}, extension_capabilities())
      )

    assert result["state"] == %{"token" => "extension-state"}

    assert :ok = FastestMCP.stop_server(server_name)
    assert_receive :lifespan_cleanup
  end

  test "tool interceptors run in declaration order only when negotiated and wrap mounted tools" do
    server_name = unique_name("active-interceptor")
    test_pid = self()

    child =
      FastestMCP.server("#{server_name}-child")
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

    first =
      ServerExtension.new("com.example/first",
        tool_interceptor: fn operation, next ->
          send(test_pid, {:interceptor, :first, operation.target})
          next.(operation)
        end
      )

    second =
      ServerExtension.new("com.example/second",
        tool_interceptor: fn operation, next ->
          send(test_pid, {:interceptor, :second, operation.target})
          next.(operation)
        end
      )

    server =
      FastestMCP.server(server_name, active_extensions: [first, second])
      |> FastestMCP.mount(child, namespace: "child")

    start_server!(server)

    params = %{"name" => "child_echo", "arguments" => %{"ok" => true}}

    result =
      Engine.dispatch!(
        server_name,
        modern_request("tools/call", params, %{
          "extensions" => %{
            "com.example/first" => %{},
            "com.example/second" => %{}
          }
        })
      )

    assert result["structuredContent"] == %{"ok" => true}
    assert_receive {:interceptor, :first, "child_echo"}
    assert_receive {:interceptor, :second, "child_echo"}

    _result = Engine.dispatch!(server_name, modern_request("tools/call", params, %{}))
    refute_receive {:interceptor, _, _}
  end

  test "connected clients send configured extensions on generic low-level requests" do
    server_name = unique_name("active-client")

    handler = fn params, context ->
      %{
        "params" => params,
        "clientSettings" => Extensions.settings(context.client_capabilities, @extension_id)
      }
    end

    server =
      FastestMCP.server(server_name,
        active_extensions: [
          ServerExtension.new(@extension_id,
            settings: %{"server" => true},
            methods: [ServerExtension.method("example/run", handler)]
          )
        ]
      )

    start_server!(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: ["127.0.0.1", "localhost"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    endpoint = "http://127.0.0.1:#{port}/mcp"

    client =
      Client.connect!(endpoint,
        protocol_version: @modern_version,
        extensions: %{@extension_id => %{"client" => true}}
      )

    unnegotiated = Client.connect!(endpoint, protocol_version: @modern_version)

    legacy =
      Client.connect!(endpoint,
        protocol_version: "2025-11-25",
        extensions: %{@extension_id => %{}}
      )

    on_exit(fn ->
      for connected_client <- [client, unnegotiated, legacy] do
        if Client.connected?(connected_client), do: Client.disconnect(connected_client)
      end
    end)

    assert %{
             "params" => %{"value" => 11},
             "clientSettings" => %{"client" => true},
             "resultType" => "complete"
           } = Client.request(client, "example/run", %{"value" => 11})

    request = Client.request_async(client, "example/run", %{"value" => 12})
    assert get_in(Client.await(request), ["params", "value"]) == 12

    negotiation_error =
      assert_raise Error, fn ->
        Client.request(unnegotiated, "example/run", %{"value" => 13})
      end

    assert negotiation_error.code == :missing_required_client_capability

    legacy_error =
      assert_raise Error, fn ->
        Client.request(legacy, "example/run", %{"value" => 14})
      end

    assert legacy_error.code == :method_not_found
  end

  defp modern_request(method, params, client_capabilities, request_id \\ nil) do
    request_id = request_id || System.unique_integer([:positive])

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "extension-test", "version" => "1"}
    }

    %Request{
      method: method,
      transport: :stdio,
      protocol: :jsonrpc,
      protocol_version: @modern_version,
      request_id: request_id,
      payload: Map.put(Map.new(params), "_meta", meta)
    }
  end

  defp extension_capabilities do
    %{"extensions" => %{@extension_id => %{}}}
  end

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
