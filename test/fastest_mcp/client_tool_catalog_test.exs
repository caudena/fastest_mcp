defmodule FastestMCP.ClientToolCatalogTest do
  use FastestMCP.Case, async: true

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Error
  alias FastestMCP.Middleware

  defmodule CatalogPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)

      case request do
        %{"id" => id, "method" => "initialize"} ->
          reply(
            conn,
            id,
            %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{
                "tools" => %{},
                "tasks" => %{"requests" => %{"tools" => %{"call" => %{}}}}
              },
              "serverInfo" => %{"name" => "catalog-test", "version" => "1.0.0"}
            },
            [{"mcp-session-id", "catalog-session"}]
          )

        %{"method" => "notifications/initialized"} ->
          send_resp(conn, 202, "")

        %{"id" => id, "method" => "tools/list", "params" => params} ->
          cursor = Map.get(params, "cursor")
          mode = Agent.get(state, & &1.mode)
          authorization = conn |> get_req_header("authorization") |> List.first()

          request_number =
            Agent.get_and_update(state, fn current ->
              count = current.list_requests + 1
              {count, %{current | list_requests: count}}
            end)

          if mode == :single_flight and is_nil(cursor) and request_number == 1 do
            send(test_pid, {:catalog_first_page, self()})

            receive do
              :release_catalog -> :ok
            after
              2_000 -> :ok
            end
          end

          reply(conn, id, catalog_page(mode, cursor, authorization))

        %{"id" => id, "method" => "tools/call", "params" => params} ->
          Agent.update(state, fn current ->
            update_in(current.calls, &[params | &1])
          end)

          value = get_in(params, ["arguments", "value"])

          structured =
            if Agent.get(state, &(&1.mode == :invalid_output)) do
              %{"value" => Integer.to_string(value)}
            else
              %{"value" => value}
            end

          reply(conn, id, %{
            "content" => [%{"type" => "text", "text" => JSON.encode!(structured)}],
            "structuredContent" => structured
          })
      end
    end

    defp catalog_page(:auth_partition, nil, authorization) do
      token = String.replace_prefix(authorization || "anonymous", "Bearer ", "")
      %{"tools" => [echo_descriptor("#{token}_tool")]}
    end

    defp catalog_page(:repeated_cursor, nil, _authorization) do
      %{"tools" => [echo_descriptor()], "nextCursor" => "repeat"}
    end

    defp catalog_page(:repeated_cursor, "repeat", _authorization) do
      %{"tools" => [], "nextCursor" => "repeat"}
    end

    defp catalog_page(_mode, nil, _authorization) do
      %{
        "tools" => [
          %{
            "name" => "broken",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "value" => %{"$ref" => "#/$defs/missing"}
              }
            }
          }
        ],
        "nextCursor" => "page-2"
      }
    end

    defp catalog_page(_mode, "page-2", _authorization) do
      %{
        "tools" => [
          echo_descriptor(),
          %{
            "name" => "required-task",
            "inputSchema" => %{"type" => "object"},
            "execution" => %{"taskSupport" => "required"}
          }
        ]
      }
    end

    defp echo_descriptor(name \\ "echo") do
      %{
        "name" => name,
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"],
          "additionalProperties" => false
        },
        "outputSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"],
          "additionalProperties" => false
        }
      }
    end

    defp reply(conn, id, result, headers \\ []) do
      conn =
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  defmodule StaleListPlug do
    @moduledoc false
    # A 2026-07-28 server whose tool lists are stale at once (ttlMs 0). It
    # counts tools/list requests and lists the tools its Agent holds.
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      %{"id" => id, "method" => method} = JSON.decode!(body)
      state = Keyword.fetch!(opts, :state)
      cacheable = %{"ttlMs" => 0, "cacheScope" => "private"}

      result =
        case method do
          "server/discover" ->
            Map.merge(cacheable, %{
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{"tools" => %{"listChanged" => true}}
            })

          "tools/list" ->
            tools = Agent.get_and_update(state, &{&1.tools, %{&1 | lists: &1.lists + 1}})

            Map.put(
              cacheable,
              "tools",
              Enum.map(tools, &%{"name" => &1, "inputSchema" => %{"type" => "object"}})
            )

          "tools/call" ->
            %{"content" => [%{"type" => "text", "text" => "ok"}]}
        end

      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => Map.put(result, "resultType", "complete")
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(response))
    end
  end

  test "calls reuse a stale tool list and list again for a tool it lacks" do
    state = start_supervised!({Agent, fn -> %{tools: ["echo"], lists: 0} end})
    %{url: url} = serve!({StaleListPlug, state: state})
    client = connect!(url, protocol_version: "2026-07-28")

    assert {:ok, _result} = Client.call_tool(client, "echo")
    assert {:ok, _result} = Client.call_tool(client, "echo")
    assert Agent.get(state, & &1.lists) == 1

    Agent.update(state, &%{&1 | tools: ["echo", "later"]})
    assert {:ok, _result} = Client.call_tool(client, "later")
    assert Agent.get(state, & &1.lists) == 2

    assert {:error, %Error{code: :method_not_found}} = Client.call_tool(client, "missing")
    assert Agent.get(state, & &1.lists) == 3

    # Listing honours the server's ttlMs.
    assert {:ok, [%{"name" => "echo"}, %{"name" => "later"}]} = Client.list_all_tools(client)
    assert Agent.get(state, & &1.lists) == 4
  end

  test "catalog discovery is complete, paginated, single-flight, and isolates bad descriptors" do
    {client, state} = start_client(:single_flight)

    first = Task.async(fn -> Client.call_tool!(client, "echo", %{"value" => 1}) end)
    second = Task.async(fn -> Client.call_tool!(client, "echo", %{"value" => 2}) end)

    assert_receive {:catalog_first_page, loader_pid}, 1_000
    # The second caller joins the load in flight instead of listing again.
    refute_receive {:catalog_first_page, _second_loader}, 50
    assert Agent.get(state, & &1.list_requests) == 1
    send(loader_pid, :release_catalog)

    assert %{structured_content: %{"value" => 1}} = Task.await(first, 1_000)
    assert %{structured_content: %{"value" => 2}} = Task.await(second, 1_000)
    assert Agent.get(state, & &1.list_requests) == 2
    assert length(Agent.get(state, & &1.calls)) == 2

    assert_raise ProtocolError, fn -> Client.call_tool!(client, "broken", %{}) end

    invalid_arguments =
      assert_raise Error, fn -> Client.call_tool!(client, "echo", %{"value" => "one"}) end

    assert invalid_arguments.code == :invalid_params

    required_task =
      assert_raise Error, fn -> Client.call_tool!(client, "required-task", %{}) end

    assert required_task.code == :method_not_found

    assert %{structured_content: %{"value" => 3}} =
             Client.call_tool!(client, "echo", %{"value" => 3}, task: false)

    assert length(Agent.get(state, & &1.calls)) == 3
    assert Agent.get(state, & &1.list_requests) == 2
  end

  test "a tool schema reference the client cannot resolve is named in the protocol error" do
    name = unique_name("catalog-unresolved-reference")
    remote_uri = "https://schemas.example/tag.json"
    resolver = fn ^remote_uri -> {:ok, %{"type" => "string"}} end

    FastestMCP.server(name, schema_options: [resolver: resolver])
    |> FastestMCP.add_tool("tag_note", fn %{"tag" => tag}, _ctx -> tag end,
      input_schema: %{
        "type" => "object",
        "properties" => %{"tag" => %{"$ref" => remote_uri}},
        "required" => ["tag"]
      }
    )
    |> start_server!()

    client = connect!({:in_process, name})

    assert {:error, %ProtocolError{method: "tools/list", violations: [violation]}} =
             Client.call_tool(client, "tag_note", %{"tag" => "release"})

    assert violation.tool == "tag_note"
    assert violation.message =~ remote_uri
  end

  test "direct tool results are checked against the catalog output schema" do
    {client, _state} = start_client(:invalid_output)

    error =
      assert_raise ProtocolError, fn ->
        Client.call_tool!(client, "echo", %{"value" => 7})
      end

    assert error.method == "tools/call"
    assert error.violations != []
  end

  test "catalog discovery rejects repeated pagination cursors" do
    {client, _state} = start_client(:repeated_cursor)

    error =
      assert_raise Error, fn ->
        Client.call_tool!(client, "echo", %{"value" => 1})
      end

    assert error.code == :invalid_request
    assert error.message == "tools/list returned a repeated cursor"
  end

  test "catalogs stay fresh without legacy TTL hints and invalidate on auth setters" do
    {client, state} = start_client(:auth_partition, access_token: "alpha")

    assert %{structured_content: %{"value" => 1}} =
             Client.call_tool!(client, "alpha_tool", %{"value" => 1})

    assert %{structured_content: %{"value" => 2}} =
             Client.call_tool!(client, "alpha_tool", %{"value" => 2})

    assert Agent.get(state, & &1.list_requests) == 1

    assert :ok = Client.set_auth!(client, access_token: "beta")

    assert %{structured_content: %{"value" => 3}} =
             Client.call_tool!(client, "beta_tool", %{"value" => 3})

    assert Agent.get(state, & &1.list_requests) == 2

    assert :ok = Client.set_auth!(client, authorization: "Bearer gamma")

    assert %{structured_content: %{"value" => 4}} =
             Client.call_tool!(client, "gamma_tool", %{"value" => 4})

    assert Agent.get(state, & &1.list_requests) == 3
  end

  test "listing and execution reuse one compiled catalog while it is fresh" do
    parent = self()
    name = unique_name("catalog-reuse")

    FastestMCP.server(name)
    |> FastestMCP.add_middleware(fn operation, next ->
      if operation.method == "tools/list", do: send(parent, :catalog_loaded)
      next.(operation)
    end)
    |> FastestMCP.add_tool("echo", fn arguments, _ -> arguments end)
    |> start_server!()

    client = connect!({:in_process, name}, protocol_version: "2025-11-25")

    assert {:ok, [%{"name" => "echo"}]} = Client.list_all_tools(client)
    assert_receive :catalog_loaded
    assert {:ok, %Client.ToolResult{structured_content: %{}}} = Client.call_tool(client, "echo")
    assert {:ok, [%{"name" => "echo"}]} = Client.list_all_tools(client)
    refute_receive :catalog_loaded
    assert :ok = Client.set_auth(client, [])
    assert {:ok, _} = Client.list_all_tools(client)
    assert_receive :catalog_loaded
  end

  test "per-call authentication discovery does not replace the connection catalog" do
    parent = self()
    name = unique_name("catalog-per-call-auth")

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_auth(fn input, _ ->
        token =
          case input["authorization"] do
            "Bearer " <> token -> token
            _ -> input["token"]
          end

        {:ok, %{principal: token}}
      end)
      |> FastestMCP.add_middleware(fn operation, next ->
        result = next.(operation)

        if operation.method == "tools/list" do
          send(parent, {:catalog_for, operation.context.principal})

          Middleware.map_result(result, fn tools ->
            Enum.filter(tools, &(&1.name == operation.context.principal))
          end)
        else
          result
        end
      end)
      |> FastestMCP.add_tool("alpha", fn _, _ -> %{} end)
      |> FastestMCP.add_tool("beta", fn _, _ -> %{} end)

    start_server!(server)

    client =
      connect!({:in_process, name},
        auth_input: %{token: "alpha"},
        protocol_version: "2025-11-25"
      )

    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(client)
    assert_receive {:catalog_for, "alpha"}

    assert {:ok, [%{"name" => "beta"}]} =
             Client.list_all_tools(client, auth_input: %{token: "beta"})

    assert_receive {:catalog_for, "beta"}

    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(client)
    refute_receive {:catalog_for, _}

    assert_raise ArgumentError, fn -> Client.list_all_tools(client, access_token: "beta") end

    %{url: url} = start_http!(name)
    http_client = connect!(url, access_token: "alpha", protocol_version: "2026-07-28")
    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(http_client)
    assert_receive {:catalog_for, "alpha"}

    for options <- [
          [access_token: "beta"],
          [authorization: "Bearer beta"],
          [headers: [{"authorization", "Bearer beta"}]]
        ] do
      assert {:ok, [%{"name" => "beta"}]} = Client.list_all_tools(http_client, options)
      assert_receive {:catalog_for, "beta"}
    end

    # The connection's own list is still fresh, so it isn't fetched again.
    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(http_client)
    refute_receive {:catalog_for, _}
  end

  test "invalid preferred descriptors do not fall back to older valid versions" do
    descriptor = fn version, schema ->
      %{
        "name" => "versioned",
        "inputSchema" => schema,
        "_meta" => %{"fastestmcp" => %{"version" => version}}
      }
    end

    catalog =
      ToolCatalog.build(
        [
          descriptor.("1.0.0", %{"type" => "object"}),
          descriptor.("2.0.0", %{"type" => "not-a-json-type"})
        ],
        3,
        []
      )

    assert {:ok, %{version: "1.0.0"}} = ToolCatalog.lookup(catalog, "versioned", "1.0.0")
    assert {:error, _} = ToolCatalog.lookup(catalog, "versioned")
    assert {:error, _} = ToolCatalog.lookup(catalog, "versioned", "2.0.0")
  end

  defp start_client(mode, opts \\ []) do
    state = start_supervised!({Agent, fn -> %{mode: mode, list_requests: 0, calls: []} end})

    %{url: url} = serve!({CatalogPlug, state: state, test_pid: self()})

    client =
      connect!(
        url,
        Keyword.merge([protocol_version: "2025-11-25"], opts)
      )

    {client, state}
  end
end
