defmodule FastestMCP.RefactorContractTest do
  use ExUnit.Case, async: false

  alias FastestMCP.{Client, ClientGroup, Error, Middleware, Operation}
  alias FastestMCP.Client.{ToolCatalog, ToolResult}
  alias FastestMCP.Tools.Result

  test "tagged and bang calls preserve plain maps, explicit envelopes, text and null" do
    name = unique_name()

    data = %{
      "content" => [],
      "structuredContent" => false,
      "isError" => true,
      "messages" => [],
      "contents" => []
    }

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_tool("data", fn _, _ -> data end)
      |> FastestMCP.add_tool("text", fn _, _ -> "false" end)
      |> FastestMCP.add_tool("envelope", fn _, _ ->
        Result.from_raw(%{
          "content" => [],
          "structuredContent" => nil,
          "vendor" => %{"future" => 1}
        })
      end)
      |> FastestMCP.add_tool("error", fn _, _ -> Result.new("declined", is_error: true) end)
      |> FastestMCP.add_resource("data://plain", fn _, _ -> data end)
      |> FastestMCP.add_prompt("plain", fn _, _ -> data end)

    start_server(server)
    {:ok, client} = Client.connect({:in_process, name})
    on_exit(fn -> Client.disconnect(client) end)

    assert {:ok, ^data} = FastestMCP.call_tool(name, "data")

    assert {:ok, %ToolResult{structured_content: ^data, is_error: false}} =
             Client.call_tool(client, "data")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "false"}],
             structured_content_present?: false
           } =
             Client.call_tool!(client, "text")

    assert {:ok,
            %ToolResult{
              structured_content: nil,
              structured_content_present?: true,
              raw: %{"vendor" => %{"future" => 1}}
            }} =
             Client.call_tool(client, "envelope")

    assert {:ok, %ToolResult{is_error: true}} = Client.call_tool(client, "error")
    assert {:error, %Error{code: :method_not_found}} = Client.call_tool(client, "missing")
    assert_raise Error, fn -> Client.call_tool!(client, "missing") end
    assert {:error, %Error{}} = FastestMCP.call_tool(name, "missing")

    assert {:ok, %{"contents" => [%{"text" => resource_text}]}} =
             Client.request(client, "resources/read", %{"uri" => "data://plain"})

    assert JSON.decode!(resource_text) == data

    assert {:ok, %{"messages" => [%{"content" => %{"text" => prompt_text}}]}} =
             Client.render_prompt(client, "plain")

    assert JSON.decode!(prompt_text) == data
  end

  test "listing and execution reuse one compiled catalog while it is fresh" do
    parent = self()
    name = unique_name()

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_middleware(fn operation, next ->
        if operation.method == "tools/list", do: send(parent, :catalog_loaded)
        next.(operation)
      end)
      |> FastestMCP.add_tool("echo", fn arguments, _ -> arguments end)

    start_server(server)
    client = Client.connect!({:in_process, name}, protocol_version: "2025-11-25")
    on_exit(fn -> Client.disconnect(client) end)

    assert {:ok, [%{"name" => "echo"}]} = Client.list_all_tools(client)
    assert_receive :catalog_loaded
    assert {:ok, %ToolResult{structured_content: %{}}} = Client.call_tool(client, "echo")
    assert {:ok, [%{"name" => "echo"}]} = Client.list_all_tools(client)
    refute_receive :catalog_loaded
    assert :ok = Client.set_auth_input(client, %{})
    assert {:ok, _} = Client.list_all_tools(client)
    assert_receive :catalog_loaded
  end

  test "per-call authentication discovery does not replace the connection catalog" do
    parent = self()
    name = unique_name()

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
          Enum.filter(result, &(&1.name == operation.context.principal))
        else
          result
        end
      end)
      |> FastestMCP.add_tool("alpha", fn _, _ -> %{} end)
      |> FastestMCP.add_tool("beta", fn _, _ -> %{} end)

    start_server(server)

    client =
      Client.connect!({:in_process, name},
        auth_input: %{token: "alpha"},
        protocol_version: "2025-11-25"
      )

    on_exit(fn -> Client.disconnect(client) end)
    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(client)
    assert_receive {:catalog_for, "alpha"}

    assert {:ok, [%{"name" => "beta"}]} =
             Client.list_all_tools(client, auth_input: %{token: "beta"})

    assert_receive {:catalog_for, "beta"}

    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(client)
    refute_receive {:catalog_for, _}

    assert {:error, %Error{code: :invalid_params}} =
             Client.list_all_tools(client, access_token: "beta")

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: name, path: "/mcp", allowed_hosts: :localhost},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    http_client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        access_token: "alpha",
        protocol_version: "2026-07-28"
      )

    on_exit(fn -> Client.disconnect(http_client) end)
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

    assert {:ok, [%{"name" => "alpha"}]} = Client.list_all_tools(http_client)
    # The modern server advertises ttlMs: 0, so its default identity is fetched again.
    assert_receive {:catalog_for, "alpha"}
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

  test "dispatch uses an updated immutable middleware configuration" do
    parent = self()
    configured = Middleware.timing(log_fn: fn _, message -> send(parent, {:old, message}) end)
    updated = %{configured | log_fn: fn _, message -> send(parent, {:new, message}) end}
    operation = %Operation{method: "tools/list"}
    assert :result = Middleware.run([updated], operation, fn _ -> :result end)
    assert_receive {:new, _}
    refute_receive {:old, _}
  end

  test "a coordinator failure completes a terminal handle with a tagged error" do
    parent = self()
    name = unique_name()

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_tool("block", fn _, _ ->
        send(parent, :handler_started)

        receive do
          :finish -> "done"
        end
      end)

    start_server(server)
    client = Client.connect!({:in_process, name})
    on_exit(fn -> Client.disconnect(client) end)
    {:ok, request} = Client.start_tool_result(client, "block")
    assert_receive :handler_started
    Process.exit(request.pid, :kill)
    assert {:error, %Error{code: :internal_error}} = Client.await_tool_result(request, 1_000)
  end

  test "explicit cancellation releases the caller monitor and remains awaitable" do
    parent = self()
    name = unique_name()

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_tool("block", fn _, _ ->
        send(parent, :handler_started)

        receive do
          :finish -> "done"
        end
      end)

    start_server(server)
    client = Client.connect!({:in_process, name})
    on_exit(fn -> Client.disconnect(client) end)

    {:ok, request} =
      Client.request_async(client, "tools/call", %{"name" => "block", "arguments" => %{}})

    assert_receive :handler_started
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    assert {:process, client.pid} in monitors
    assert :ok = Client.cancel(request)
    assert {:monitors, monitors} = Process.info(self(), :monitors)
    refute {:process, client.pid} in monitors
    assert {:error, %Error{code: :cancelled}} = Client.await(request, 1_000)
  end

  test "low-level await reports connection death instead of waiting forever" do
    parent = self()
    name = unique_name()

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_tool("block", fn _, _ ->
        send(parent, :handler_started)

        receive do
          :finish -> "done"
        end
      end)

    start_server(server)
    client = Client.connect!({:in_process, name})
    Process.unlink(client.pid)

    {:ok, request} =
      Client.request_async(client, "tools/call", %{"name" => "block", "arguments" => %{}})

    assert_receive :handler_started
    Process.exit(client.pid, :kill)
    assert {:error, %Error{code: :internal_error}} = Client.await(request, 1_000)
  end

  test "unnamed handles and named coordinators share tagged group operations" do
    name = unique_name()
    start_server(FastestMCP.server(name) |> FastestMCP.add_tool("echo", fn _, _ -> %{} end))
    {:ok, group} = ClientGroup.connect(clients: %{"local" => [target: {:in_process, name}]})
    assert {:ok, [%{"name" => "local_echo"}]} = ClientGroup.list_tools(group)
    assert {:ok, %ToolResult{}} = ClientGroup.call_tool(group, "local_echo")
    assert :ok = ClientGroup.disconnect(group)
    assert {:error, %Error{code: :not_found}} = ClientGroup.list_tools(group)

    registered = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      {ClientGroup, name: registered, clients: %{"local" => [target: {:in_process, name}]}}
    )

    assert {:ok, [%{"name" => "local_echo"}]} = ClientGroup.list_tools(registered)
  end

  defp start_server(server) do
    {:ok, _} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_name, do: "refactor-#{System.unique_integer([:positive])}"
end
