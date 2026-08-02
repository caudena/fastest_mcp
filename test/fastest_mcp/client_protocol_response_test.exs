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
          "capabilities" => %{},
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
      "result" => %{"tools" => [%{"name" => "from-sse"}]}
    })
  end

  defp respond(conn, :sse, %{"id" => id, "method" => "ping"}) do
    send_sse(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
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
  alias FastestMCP.Error

  test "all HTTP request families accept bounded SSE responses" do
    url = start_protocol_server(:sse)
    client = Client.connect!(url)
    on_exit(fn -> disconnect_if_alive(client) end)

    assert Client.session_id(client) == "all-sse-session"
    assert %{items: [%{"name" => "from-sse"}], next_cursor: nil} = Client.list_tools(client)
    assert %{} = Client.ping(client)
  end

  test "HTTP JSON and SSE responses require valid correlated JSON-RPC envelopes" do
    url = start_protocol_server(:invalid_envelopes)
    client = Client.connect!(url, auto_initialize: false)
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

  test "client decodes standard and FastestMCP JSON-RPC error semantics" do
    url = start_protocol_server(:error_semantics)
    client = Client.connect!(url, auto_initialize: false)
    on_exit(fn -> disconnect_if_alive(client) end)

    assert_error_code(:method_not_found, fn -> Client.ping(client) end)
    assert_error_code(:invalid_params, fn -> Client.list_tools(client) end)
    assert_error_code(:not_found, fn -> Client.list_resources(client) end)
    assert_error_code(:method_not_found, fn -> Client.list_prompts(client) end)
    assert_error_code(:invalid_task_id, fn -> Client.fetch_task(client, "missing-task") end)
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
