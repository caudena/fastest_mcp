defmodule FastestMCP.ClientToolCatalogTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Error

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
              "protocolVersion" => FastestMCP.Protocol.current_version(),
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

          reply(conn, id, catalog_page(mode, cursor))

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

    defp catalog_page(:repeated_cursor, nil) do
      %{"tools" => [echo_descriptor()], "nextCursor" => "repeat"}
    end

    defp catalog_page(:repeated_cursor, "repeat") do
      %{"tools" => [], "nextCursor" => "repeat"}
    end

    defp catalog_page(_mode, nil) do
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

    defp catalog_page(_mode, "page-2") do
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

    defp echo_descriptor do
      %{
        "name" => "echo",
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

  test "catalog discovery is complete, paginated, single-flight, and isolates bad descriptors" do
    {client, state} = start_client(:single_flight)

    first = Task.async(fn -> Client.call_tool(client, "echo", %{"value" => 1}) end)
    second = Task.async(fn -> Client.call_tool(client, "echo", %{"value" => 2}) end)

    assert_receive {:catalog_first_page, loader_pid}, 1_000
    Process.sleep(50)
    assert Agent.get(state, & &1.list_requests) == 1
    send(loader_pid, :release_catalog)

    assert %{"value" => 1} = Task.await(first, 1_000)
    assert %{"value" => 2} = Task.await(second, 1_000)
    assert Agent.get(state, & &1.list_requests) == 2
    assert length(Agent.get(state, & &1.calls)) == 2

    assert_raise ProtocolError, fn -> Client.call_tool(client, "broken", %{}) end

    invalid_arguments =
      assert_raise Error, fn -> Client.call_tool(client, "echo", %{"value" => "one"}) end

    assert invalid_arguments.code == :invalid_params

    required_task =
      assert_raise Error, fn -> Client.call_tool(client, "required-task", %{}) end

    assert required_task.code == :method_not_found
    assert %{"value" => 3} = Client.call_tool(client, "echo", %{"value" => 3}, task: false)
    assert length(Agent.get(state, & &1.calls)) == 3
  end

  test "direct tool results are checked against the catalog output schema" do
    {client, _state} = start_client(:invalid_output)

    error =
      assert_raise ProtocolError, fn ->
        Client.call_tool(client, "echo", %{"value" => 7})
      end

    assert error.method == "tools/call"
    assert error.violations != []
  end

  test "catalog discovery rejects repeated pagination cursors" do
    {client, _state} = start_client(:repeated_cursor)

    error =
      assert_raise Error, fn ->
        Client.call_tool(client, "echo", %{"value" => 1})
      end

    assert error.code == :invalid_request
    assert error.message == "tools/list returned a repeated cursor"
  end

  defp start_client(mode) do
    state = start_supervised!({Agent, fn -> %{mode: mode, list_requests: 0, calls: []} end})

    bandit =
      start_supervised!(
        {Bandit, plug: {CatalogPlug, state: state, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    {client, state}
  end
end
