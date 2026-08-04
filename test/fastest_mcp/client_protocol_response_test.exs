defmodule FastestMCP.TestSupport.ClientProtocolResponsePlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "DELETE"} = conn, _opts), do: send_resp(conn, 204, "")

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)

    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:client_protocol_request, request})
    end

    respond(conn, Keyword.fetch!(opts, :mode), request)
  end

  defp respond(conn, :sse, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :sse, %{"id" => id, "method" => "initialize"}) do
    send_sse(
      conn,
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => FastestMCP.Protocol.current_version(),
          "capabilities" => %{"logging" => %{}, "tools" => %{}},
          "serverInfo" => %{"name" => "all-sse", "version" => "1.0.0"}
        }
      },
      [{"mcp-session-id", "all-sse-session"}]
    )
  end

  defp respond(conn, :sse, %{"id" => id, "method" => "tools/list"}) do
    send_sse(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{"name" => "from-sse", "inputSchema" => %{"type" => "object"}}
        ]
      }
    })
  end

  defp respond(conn, :sse, %{"id" => id, "method" => "ping"}) do
    send_sse(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp respond(conn, :sse, %{"id" => id, "method" => "logging/setLevel"}) do
    send_sse(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp respond(conn, mode, %{"method" => "notifications/initialized"})
       when mode in [:invalid_envelopes, :error_semantics] do
    send_resp(conn, 202, "")
  end

  defp respond(conn, mode, %{"id" => id, "method" => "initialize"})
       when mode in [:invalid_envelopes, :error_semantics] do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{
          "tools" => %{},
          "resources" => %{},
          "prompts" => %{},
          "tasks" => %{}
        },
        "serverInfo" => %{"name" => Atom.to_string(mode), "version" => "1.0.0"}
      }
    })
  end

  defp respond(conn, :invalid_envelopes, %{"id" => id, "method" => "ping"}) do
    send_json(conn, %{"jsonrpc" => "1.0", "id" => id, "result" => %{}})
  end

  defp respond(conn, :invalid_envelopes, %{"method" => "tools/list"}) do
    send_json(conn, %{"jsonrpc" => "2.0", "id" => "wrong-id", "result" => %{"tools" => []}})
  end

  defp respond(conn, :invalid_envelopes, %{"id" => id, "method" => "prompts/list"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"prompts" => []},
      "error" => %{"code" => -32_603, "message" => "invalid"}
    })
  end

  defp respond(conn, :invalid_envelopes, %{"id" => id, "method" => "resources/list"}) do
    send_sse(conn, %{"jsonrpc" => "1.0", "id" => id, "result" => %{"resources" => []}})
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "ping"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "unknown method"}
    })
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "tools/list"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_602, "message" => "invalid params"}
    })
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "resources/list"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_602,
        "message" => "missing resource",
        "data" => %{"fastestmcp" => %{"code" => "not_found"}}
      }
    })
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "prompts/list"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_601,
        "message" => "missing callback method",
        "data" => %{"fastestmcp" => %{"code" => "method_not_found"}}
      }
    })
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "tasks/get"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_602,
        "message" => "missing task",
        "data" => %{"fastestmcp" => %{"code" => "invalid_task_id"}}
      }
    })
  end

  defp respond(conn, :error_semantics, %{"id" => id, "method" => "resources/read"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_042,
        "message" => "URL elicitation is required",
        "data" => %{
          "elicitations" => [%{"elicitationId" => "url-1", "url" => "https://example.com"}],
          "fastestmcp" => %{"code" => "url_elicitation_required"}
        }
      }
    })
  end

  defp respond(conn, :unsupported_initialize, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :unsupported_initialize, %{"id" => id, "method" => "initialize"}) do
    send_json(
      conn,
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "serverInfo" => %{"name" => "old-server", "version" => "1.0.0"}
        }
      },
      [{"mcp-session-id", "unsupported-session"}]
    )
  end

  defp respond(conn, :invalid_initialize, %{"id" => id, "method" => "initialize"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{},
        "serverInfo" => %{"name" => "missing-required-version"}
      }
    })
  end

  defp respond(conn, :invalid_method_schema, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :invalid_method_schema, %{"id" => id, "method" => "initialize"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "invalid-method-server", "version" => "1.0.0"}
      }
    })
  end

  defp respond(conn, :invalid_method_schema, %{"id" => id, "method" => "tools/list"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => [%{"name" => "missing-input-schema"}]}
    })
  end

  defp respond(conn, :invalid_media, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :invalid_media, %{"id" => id, "method" => "initialize"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "invalid-media-server", "version" => "1.0.0"}
      }
    })
  end

  defp respond(conn, :invalid_media, %{"id" => id, "method" => "tools/list"}) do
    conn
    |> put_resp_header("content-type", "application/problem+json")
    |> send_resp(
      200,
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"tools" => []}
      })
    )
  end

  defp respond(conn, mode, %{"method" => "notifications/initialized"})
       when mode in [:duplicate_same_media, :duplicate_conflicting_media] do
    send_resp(conn, 202, "")
  end

  defp respond(conn, mode, %{"id" => id, "method" => "initialize"})
       when mode in [:duplicate_same_media, :duplicate_conflicting_media] do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "duplicate-media-server", "version" => "1.0.0"}
      }
    })
  end

  defp respond(conn, mode, %{"id" => id, "method" => "tools/list"})
       when mode in [:duplicate_same_media, :duplicate_conflicting_media] do
    media_types =
      case mode do
        :duplicate_same_media -> ["application/json", "application/json"]
        :duplicate_conflicting_media -> ["application/json", "text/event-stream"]
      end

    conn
    |> prepend_resp_headers(Enum.map(media_types, &{"content-type", &1}))
    |> send_resp(
      200,
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"tools" => []}
      })
    )
  end

  defp respond(conn, :delayed_request, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :delayed_request, %{"method" => "notifications/cancelled"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, :delayed_request, %{"id" => id, "method" => "initialize"}) do
    send_json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => FastestMCP.Protocol.current_version(),
        "capabilities" => %{},
        "serverInfo" => %{"name" => "delayed-server", "version" => "1.0.0"}
      }
    })
  end

  defp respond(conn, :delayed_request, %{"id" => id, "method" => "ping"}) do
    Process.sleep(1_000)
    send_json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp send_json(conn, payload, headers \\ []) do
    conn
    |> put_headers(headers)
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(payload))
  end

  defp send_sse(conn, payload, headers \\ []) do
    conn =
      conn
      |> put_headers(headers)
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: message\ndata: #{JSON.encode!(payload)}\n\n")
    conn
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, current ->
      put_resp_header(current, name, value)
    end)
  end
end

defmodule FastestMCP.ClientProtocolResponseTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Error

  test "all HTTP request families accept bounded SSE responses" do
    url = start_protocol_server(:sse)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    assert Client.session_id(client) == "all-sse-session"

    assert %{
             items: [
               %{"name" => "from-sse", "inputSchema" => %{"type" => "object"}}
             ],
             next_cursor: nil
           } = Client.list_tools(client)

    assert %{} = Client.ping(client)
    assert :ok = Client.set_log_level(client, :warning)

    request = Client.request_async(client, "ping")
    assert %{} = Client.await(request, 2_000)
  end

  test "HTTP JSON and SSE responses require valid correlated JSON-RPC envelopes" do
    url = start_protocol_server(:invalid_envelopes)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    error = assert_raise Error, fn -> Client.ping(client) end
    assert error.code == :invalid_request
    assert error.message == ~s(JSON-RPC message must include jsonrpc: "2.0")

    error = assert_raise Error, fn -> Client.list_tools(client) end
    assert error.code == :invalid_request
    assert error.message == "JSON-RPC response id does not match the request"

    error = assert_raise Error, fn -> Client.list_prompts(client) end
    assert error.code == :invalid_request
    assert error.message == "JSON-RPC response cannot contain both result and error"

    error = assert_raise Error, fn -> Client.list_resources(client) end
    assert error.code == :invalid_request
    assert error.message == ~s(JSON-RPC message must include jsonrpc: "2.0")
  end

  test "unsupported initialize responses are rejected before initialized notification" do
    url = start_protocol_server(:unsupported_initialize, test_pid: self())

    assert {:error, %Error{} = error} = Client.connect(url)
    assert error.code == :invalid_request
    assert error.message == ~s(server returned an unsupported protocolVersion "2025-03-26")

    assert_receive {:client_protocol_request, %{"method" => "initialize"}}
    refute_receive {:client_protocol_request, %{"method" => "notifications/initialized"}}, 100
  end

  test "supported_protocol_versions cannot override the single supported baseline" do
    url = start_protocol_server(:unsupported_initialize)

    assert {:error, %Error{} = error} =
             Client.connect(url,
               supported_protocol_versions: [
                 FastestMCP.Protocol.current_version(),
                 "2025-03-26"
               ]
             )

    assert error.code == :invalid_params
    assert error.message =~ "is not configurable"
  end

  test "invalid InitializeResult aborts connection with its method-specific ProtocolError" do
    url = start_protocol_server(:invalid_initialize, test_pid: self())

    assert {:error, %ProtocolError{} = error} = Client.connect(url)
    assert error.method == "initialize"
    assert error.direction == :server_to_client
    assert error.kind == :response
    assert error.errors != []

    assert_receive {:client_protocol_request, %{"method" => "initialize"}}
    refute_receive {:client_protocol_request, %{"method" => "notifications/initialized"}}, 100

    assert_raise ProtocolError, fn -> Client.connect!(url) end
  end

  test "method-specific response schemas reject structurally invalid results" do
    url = start_protocol_server(:invalid_method_schema)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    error = assert_raise ProtocolError, fn -> Client.list_tools(client) end
    assert error.method == "tools/list"
    assert error.direction == :server_to_client
    assert error.kind == :response
    assert is_binary(error.request_id)
    assert error.errors != []
    assert error.errors == error.violations
    assert error.violations != []
  end

  test "MCP responses reject non-protocol structured JSON media types" do
    url = start_protocol_server(:invalid_media)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    error = assert_raise Error, fn -> Client.list_tools(client) end
    assert error.code == :bad_request
    assert error.message == "HTTP MCP response has an unsupported Content-Type"
    assert error.details.content_type == "application/problem+json"
  end

  test "MCP responses reject duplicate Content-Type fields" do
    for mode <- [:duplicate_same_media, :duplicate_conflicting_media] do
      url = start_protocol_server(mode)
      client = Client.connect!(url)

      error = assert_raise Error, fn -> Client.list_tools(client) end
      assert error.code == :bad_request
      assert error.message == "HTTP MCP response has an unsupported Content-Type"
      assert length(error.details.content_type) == 2

      disconnect_if_alive(client)
    end
  end

  test "initialize rejects standard capabilities that the client cannot serve" do
    url = start_protocol_server(:sse)
    client = Client.connect!(url, auto_initialize: false)
    on_exit(fn -> disconnect_if_alive(client) end)

    error =
      assert_raise Error, fn ->
        Client.initialize(client, %{"capabilities" => %{"roots" => %{"listChanged" => true}}})
      end

    assert error.code == :invalid_params
    assert error.details.capability == "roots"
  end

  test "asynchronous requests can be explicitly cancelled with a protocol notification" do
    url = start_protocol_server(:delayed_request, test_pid: self())
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    request = Client.request_async(client, "ping", %{}, timeout_ms: 5_000)
    assert_receive {:client_protocol_request, %{"id" => request_id, "method" => "ping"}}, 1_000
    assert request.request_id == request_id

    assert %{direction: :client_to_server, method: "ping", request_id: ^request_id} =
             :sys.get_state(client.pid).in_flight[request.ref]

    assert :ok = Client.cancel(request, "user cancelled")

    assert_receive {:client_protocol_request,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{
                        "requestId" => ^request_id,
                        "reason" => "user cancelled"
                      }
                    }},
                   1_000

    error = assert_raise Error, fn -> Client.await(request, 1_000) end
    assert error.code == :cancelled
  end

  test "client decodes standard and FastestMCP JSON-RPC error semantics" do
    url = start_protocol_server(:error_semantics)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    assert_error_code(:method_not_found, fn -> Client.ping(client) end)
    assert_error_code(:invalid_params, fn -> Client.list_tools(client) end)
    assert_error_code(:not_found, fn -> Client.list_resources(client) end)
    assert_error_code(:method_not_found, fn -> Client.list_prompts(client) end)
    assert_error_code(:invalid_task_id, fn -> Client.fetch_task(client, "missing-task") end)

    error = assert_raise Error, fn -> Client.read_resource(client, "https://example.com") end
    assert error.code == :url_elicitation_required

    assert error.details["elicitations"] == [
             %{"elicitationId" => "url-1", "url" => "https://example.com"}
           ]
  end

  defp start_protocol_server(mode, opts \\ []) do
    plug_opts = Keyword.merge(opts, mode: mode)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FastestMCP.TestSupport.ClientProtocolResponsePlug, plug_opts},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp disconnect_if_alive(client) do
    if Client.connected?(client), do: Client.disconnect(client)
  end

  defp assert_error_code(code, fun) do
    error = assert_raise Error, fun
    assert error.code == code
  end
end
