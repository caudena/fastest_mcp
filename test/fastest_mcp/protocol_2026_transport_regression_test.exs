defmodule FastestMCP.Protocol2026TransportRegressionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP

  @modern_version "2026-07-28"

  setup do
    server_name = "protocol-2026-transport-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
      |> FastestMCP.add_tool("progress", fn _arguments, context ->
        :ok = Context.report_progress(context, 0, 100)
        :ok = Context.report_progress(context, 50, 100)
        :ok = Context.report_progress(context, 100, 100)
        "done"
      end)
      |> FastestMCP.add_tool("strict_progress", fn _arguments, context ->
        :ok = Context.report_progress(context, 1, 10)
        duplicate = Context.report_progress(context, 1, 10)
        decreasing = Context.report_progress(context, 0, 10)
        :ok = Context.report_progress(context, 2, 10)

        %{
          duplicate: duplicate |> elem(1) |> Atom.to_string(),
          decreasing: decreasing |> elem(1) |> Atom.to_string()
        }
      end)
      |> FastestMCP.add_tool("logging", fn _arguments, context ->
        Context.log(context, :debug, "hidden debug")
        Context.log(context, :info, "visible info")
        Context.log(context, :warning, "visible warning")
        "logged"
      end)
      |> FastestMCP.add_resource("test://resource", fn _arguments, _context -> "ready" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    %{server_name: server_name}
  end

  test "modern routing headers require matching body metadata before schema validation", %{
    server_name: server_name
  } do
    valid_meta = modern_meta()

    missing_protocol_params = [
      %{},
      %{"_meta" => Map.delete(valid_meta, "io.modelcontextprotocol/protocolVersion")}
    ]

    Enum.with_index(missing_protocol_params, 1)
    |> Enum.each(fn {params, id} ->
      response =
        modern_http(server_name, id, "server/discover", params, protocol_version: @modern_version)

      assert response.status == 400

      assert %{
               "id" => ^id,
               "error" => %{
                 "code" => -32_020,
                 "data" => %{"fastestmcp" => %{"code" => "header_mismatch"}}
               }
             } = JSON.decode!(response.resp_body)
    end)

    response =
      modern_http(
        server_name,
        3,
        "server/discover",
        %{"_meta" => Map.delete(valid_meta, "io.modelcontextprotocol/clientCapabilities")},
        protocol_version: @modern_version
      )

    assert response.status == 400

    assert %{
             "id" => 3,
             "error" => %{
               "code" => -32_602,
               "data" => %{"fastestmcp" => %{"code" => "invalid_params"}}
             }
           } = JSON.decode!(response.resp_body)

    duplicate_header_response =
      server_name
      |> modern_http_conn(4, "server/discover", %{"_meta" => valid_meta})
      |> then(fn request_conn ->
        %{
          request_conn
          | req_headers: [{"mcp-method", "server/discover"} | request_conn.req_headers]
        }
      end)
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

    assert duplicate_header_response.status == 400
    assert get_in(JSON.decode!(duplicate_header_response.resp_body), ["error", "code"]) == -32_020

    notification = ProtocolTest.jsonrpc_notification("server/discover", %{})

    notification_response =
      :post
      |> conn("/mcp", JSON.encode!(notification))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @modern_version)
      |> put_req_header("mcp-method", "server/discover")
      |> Map.put(:host, "localhost")
      |> StreamableHTTP.call(server_name: server_name, json_response: true)

    assert notification_response.status == 400
    assert notification_response.resp_body == ""
  end

  test "modern listeners reject malformed requests before opening over HTTP and stdio", %{
    server_name: server_name
  } do
    malformed_params = [
      %{
        "_meta" => Map.delete(modern_meta(), "io.modelcontextprotocol/clientCapabilities"),
        "notifications" => %{}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"toolsListChanged" => "yes"}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"resourceSubscriptions" => ["test://resource", 42]}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"taskIds" => ["task-1", false]}
      }
    ]

    malformed_params
    |> Enum.with_index(70)
    |> Enum.each(fn {params, id} ->
      response = modern_http(server_name, id, "subscriptions/listen", params)

      assert response.status == 400
      assert get_in(JSON.decode!(response.resp_body), ["error", "code"]) == -32_602
    end)

    input =
      malformed_params
      |> Enum.with_index(80)
      |> Enum.map(fn {params, id} ->
        ProtocolTest.jsonrpc_request(id, "subscriptions/listen", params)
        |> JSON.encode!()
        |> Kernel.<>("\n")
      end)

    {:ok, wire_io} = StringIO.open("")
    assert :ok = Stdio.serve(server_name, input, wire_io, connection_id: make_ref())

    {_input, output} = StringIO.contents(wire_io)

    responses =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.map(responses, & &1["id"]) == Enum.to_list(80..83)
    assert Enum.all?(responses, &(get_in(&1, ["error", "code"]) == -32_602))

    refute Enum.any?(responses, fn response ->
             response["method"] == "notifications/subscriptions/acknowledged"
           end)
  end

  test "unsupported versions return the exact requested and supported fields", %{
    server_name: server_name
  } do
    requested = "v999.0.0"

    response =
      modern_http(
        server_name,
        10,
        "server/discover",
        %{
          "_meta" =>
            modern_meta()
            |> Map.put("io.modelcontextprotocol/protocolVersion", requested)
        },
        protocol_version: requested
      )

    assert response.status == 400, response.resp_body

    assert %{
             "id" => 10,
             "error" => %{
               "code" => -32_022,
               "data" => %{
                 "requested" => ^requested,
                 "supported" => ["2026-07-28", "2025-11-25"]
               }
             }
           } = JSON.decode!(response.resp_body)
  end

  test "modern resource-not-found errors identify the requested URI", %{server_name: server_name} do
    uri = "test://missing-resource"

    response =
      modern_http(
        server_name,
        11,
        "resources/read",
        %{"uri" => uri, "_meta" => modern_meta()},
        name_header: uri
      )

    assert response.status == 200
    assert get_in(JSON.decode!(response.resp_body), ["error", "data", "uri"]) == uri
  end

  test "methods removed in 2026 are 404/-32601 while legacy methods remain available", %{
    server_name: server_name
  } do
    for {id, method, params} <- [
          {20, "initialize", %{}},
          {21, "ping", %{}},
          {22, "logging/setLevel", %{"level" => "debug"}},
          {23, "resources/subscribe", %{"uri" => "test://resource"}},
          {24, "resources/unsubscribe", %{"uri" => "test://resource"}}
        ] do
      response = modern_http(server_name, id, method, Map.put(params, "_meta", modern_meta()))

      assert response.status == 404
      assert get_in(JSON.decode!(response.resp_body), ["error", "code"]) == -32_601
    end

    {session_id, initialize_response} = ProtocolTest.http_initialize(server_name)
    assert initialize_response.status == 200
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    assert ProtocolTest.http_request(server_name, session_id, 30, "ping").status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             31,
             "logging/setLevel",
             %{"level" => "debug"}
           ).status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             32,
             "resources/subscribe",
             %{"uri" => "test://resource"}
           ).status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             33,
             "resources/unsubscribe",
             %{"uri" => "test://resource"}
           ).status == 200
  end

  test "modern routing headers ignore only leading and trailing HTTP OWS", %{
    server_name: server_name
  } do
    response =
      modern_http(
        server_name,
        40,
        "tools/call",
        %{
          "name" => "echo",
          "arguments" => %{"value" => "ok"},
          "_meta" => modern_meta()
        },
        protocol_version: " \t#{@modern_version}\t ",
        method_header: "\t tools/call  ",
        name_header: "  echo\t"
      )

    assert response.status == 200

    assert get_in(JSON.decode!(response.resp_body), ["result", "structuredContent", "value"]) ==
             "ok"
  end

  test "modern missing client capabilities use -32021 data while legacy keeps -32601" do
    modern = %Context{
      client_capabilities: %{},
      negotiated_protocol_version: @modern_version
    }

    modern_error = assert_raise Error, fn -> Context.list_roots(modern) end
    assert modern_error.code == :missing_required_client_capability
    assert modern_error.details.jsonrpc_code == -32_021
    assert modern_error.details.requiredCapabilities == %{"roots" => %{}}

    legacy = %Context{
      client_capabilities: %{},
      negotiated_protocol_version: "2025-11-25"
    }

    legacy_error = assert_raise Error, fn -> Context.list_roots(legacy) end
    assert legacy_error.code == :method_not_found
  end

  test "modern progress notifications travel on the originating HTTP response stream", %{
    server_name: server_name
  } do
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
    parent = self()

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        progress_handler: fn params -> send(parent, {:modern_progress, params}) end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert "done" = Client.call_tool(client, "progress", %{}, progress_token: "progress-1")

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 0, "total" => 100}},
                   1_000

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 50, "total" => 100}},
                   1_000

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 100, "total" => 100}},
                   1_000
  end

  test "modern progress is strictly increasing and invalid updates are not emitted", %{
    server_name: server_name
  } do
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
    parent = self()

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        progress_handler: fn params -> send(parent, {:strict_progress, params}) end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    result =
      Client.call_tool(client, "strict_progress", %{}, progress_token: "strict-progress")

    assert %{
             "duplicate" => "non_increasing_progress",
             "decreasing" => "non_increasing_progress"
           } = result["structuredContent"]

    assert_receive {:strict_progress, %{"progress" => 1}}, 1_000
    assert_receive {:strict_progress, %{"progress" => 2}}, 1_000
    refute_receive {:strict_progress, _params}, 100
  end

  test "modern logLevel gates logs on the originating HTTP response stream", %{
    server_name: server_name
  } do
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
    parent = self()

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        log_handler: fn params -> send(parent, {:modern_log, params}) end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert "logged" = Client.call_tool(client, "logging")
    refute_receive {:modern_log, _params}, 100

    assert "logged" =
             Client.call_tool(client, "logging", %{},
               meta: %{"io.modelcontextprotocol/logLevel" => "info"}
             )

    assert_receive {:modern_log, %{"level" => "info", "data" => "visible info"}}, 1_000

    assert_receive {:modern_log, %{"level" => "warning", "data" => "visible warning"}},
                   1_000

    refute_receive {:modern_log, %{"level" => "debug"}}, 100
  end

  defp modern_http(server_name, id, method, params, opts \\ []) do
    server_name
    |> modern_http_conn(id, method, params, opts)
    |> StreamableHTTP.call(server_name: server_name, json_response: true)
  end

  defp modern_http_conn(_server_name, id, method, params, opts \\ []) do
    payload = ProtocolTest.jsonrpc_request(id, method, params)

    :post
    |> conn("/mcp", JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header(
      "mcp-protocol-version",
      Keyword.get(opts, :protocol_version, @modern_version)
    )
    |> put_req_header("mcp-method", Keyword.get(opts, :method_header, method))
    |> maybe_put_header("mcp-name", Keyword.get(opts, :name_header))
    |> Map.put(:host, "localhost")
  end

  defp modern_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "FastestMCP regression client",
        "version" => "1.0.0"
      }
    }
  end

  defp maybe_put_header(conn, _name, nil), do: conn
  defp maybe_put_header(conn, name, value), do: put_req_header(conn, name, value)
end
