defmodule FastestMCP.HTTPAppTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.HTTPApp

  test "http_app/2 is a plug that Bandit serves and Plug.run/2 runs" do
    server_name = unique_name("http-app-plug")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    app = FastestMCP.http_app(server_name, allowed_hosts: :localhost)
    client = connect!(serve!(app).url, protocol_version: "2026-07-28")

    assert %{structured_content: %{"value" => 1}} =
             FastestMCP.Client.call_tool!(client, "echo", %{"value" => 1})

    assert %{status: 404} =
             conn(:get, "/missing") |> Map.put(:host, "localhost") |> Plug.run([app])
  end

  test "http child spec defaults to loopback and forwards Bandit options" do
    server_name = "http-child-spec-#{System.unique_integer([:positive])}"
    forwarded_options = [startup_log: false, thousand_island_options: [num_acceptors: 3]]

    assert %{
             id: {HTTPApp, ^server_name, 4_101},
             start: {Bandit, :start_link, [bandit_options]}
           } =
             FastestMCP.streamable_http_child_spec(server_name,
               port: 4_101,
               bandit_options: forwarded_options
             )

    assert Keyword.fetch!(bandit_options, :ip) == :loopback
    assert Keyword.fetch!(bandit_options, :scheme) == :http
    assert Keyword.fetch!(bandit_options, :port) == 4_101
    assert Keyword.fetch!(bandit_options, :startup_log) == false
    assert Keyword.fetch!(bandit_options, :thousand_island_options) == [num_acceptors: 3]

    assert {HTTPApp, plug_options} = Keyword.fetch!(bandit_options, :plug)
    assert Keyword.fetch!(plug_options, :server_name) == server_name
    assert Keyword.fetch!(plug_options, :bandit_options) == forwarded_options
  end

  test "http child spec validates external listener host protection" do
    server_name = "http-external-listener-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError,
                 "external HTTP listeners require a concrete allowed_hosts list",
                 fn ->
                   FastestMCP.streamable_http_child_spec(server_name,
                     bandit_options: [ip: {0, 0, 0, 0}]
                   )
                 end

    child_spec =
      FastestMCP.streamable_http_child_spec(server_name,
        bandit_options: [ip: {0, 0, 0, 0}],
        allowed_hosts: ["mcp.example.com"]
      )

    assert %{start: {Bandit, :start_link, [bandit_options]}} = child_spec
    assert Keyword.fetch!(bandit_options, :ip) == {0, 0, 0, 0}

    assert_raise ArgumentError,
                 "unsafe_allow_any_host is no longer supported; configure a concrete allowed_hosts list",
                 fn ->
                   FastestMCP.streamable_http_child_spec(server_name,
                     bandit_options: [ip: {0, 0, 0, 0}],
                     unsafe_allow_any_host: true
                   )
                 end
  end

  test "http app applies custom middleware to custom routes" do
    server_name = "http-app-routes-" <> Integer.to_string(System.unique_integer([:positive]))
    start_server!(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["www.example.com"],
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-custom-header", "test-value"))
            |> next.()
          end
        ],
        routes: [
          {:get, "/test", fn conn -> json(conn, 200, %{message: "Hello, world!"}) end}
        ]
      )

    response = conn(:get, "/test") |> Plug.run([app])

    assert response.status == 200
    assert get_resp_header(response, "x-custom-header") == ["test-value"]
    assert JSON.decode!(response.resp_body) == %{"message" => "Hello, world!"}
  end

  test "http app answers 503 on the server's routes while the server isn't running" do
    server_name = unique_name("http-app-not-running")

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["www.example.com"],
        routes: [{:get, "/health", fn conn -> json(conn, 200, %{ok: true}) end}]
      )

    # The server's routes, its metadata route among them, are unknown until
    # it runs.
    for path <- ["/mcp", "/.well-known/oauth-protected-resource/mcp", "/other"] do
      response = conn(:get, path) |> Plug.run([app])

      assert {path, response.status, get_resp_header(response, "retry-after")} ==
               {path, 503, ["1"]}
    end

    # The application's own routes don't need the server.
    assert (conn(:get, "/health") |> Plug.run([app])).status == 200
  end

  test "http app middleware can modify request state for custom routes" do
    server_name = "http-app-state-" <> Integer.to_string(System.unique_integer([:positive]))
    start_server!(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["www.example.com"],
        middleware: [
          fn conn, next ->
            conn
            |> assign(:custom_value, %{"modified_by" => "middleware"})
            |> next.()
          end
        ],
        routes: [
          {:get, "/test", fn conn -> json(conn, 200, %{state: conn.assigns.custom_value}) end}
        ]
      )

    response = conn(:get, "/test") |> Plug.run([app])

    assert response.status == 200

    assert JSON.decode!(response.resp_body) == %{
             "state" => %{"modified_by" => "middleware"}
           }
  end

  test "http app middleware also wraps MCP transport routes" do
    server_name = "http-app-mcp-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["www.example.com"],
        json_response: true,
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-transport-middleware", "applied"))
            |> next.()
          end
        ]
      )

    session_id = initialize_app(app)

    response =
      app_request(
        app,
        ProtocolTest.jsonrpc_request(2, "tools/call", %{
          "name" => "echo",
          "arguments" => %{}
        }),
        session_id
      )

    assert response.status == 200
    assert get_resp_header(response, "x-transport-middleware") == ["applied"]

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{
               "content" => [%{"type" => "text", "text" => "{}"}],
               "structuredContent" => %{}
             }
           } = JSON.decode!(response.resp_body)
  end

  test "http app rejects legacy stateless streamable HTTP options" do
    server_name = "http-app-stateless-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    assert_raise ArgumentError,
                 "stateless HTTP is no longer supported; use state_scope: :request for request-local handler state",
                 fn ->
                   FastestMCP.http_app(server_name,
                     stateless_http: true,
                     json_response: true
                   )
                 end
  end

  test "http app can reject non-local host and origin headers when allowed_hosts is configured" do
    server_name = "http-app-host-guard-" <> Integer.to_string(System.unique_integer([:positive]))
    start_server!(FastestMCP.server(server_name))

    app = FastestMCP.http_app(server_name, allowed_hosts: :localhost)

    blocked_host_log =
      capture_log(fn ->
        blocked =
          conn(
            :post,
            "/mcp",
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => ProtocolTest.initialize_params()
            })
          )
          |> Map.put(:host, "evil.example.com")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("origin", "http://evil.example.com")
          |> Plug.run([app])

        assert blocked.status == 403
      end)

    assert blocked_host_log =~ "request host is not allowed"
    assert blocked_host_log =~ ~s(received_host="evil.example.com")
    assert blocked_host_log =~ ~s(received_origins=["http://evil.example.com"])

    assert blocked_host_log =~
             ~s(allowed_hosts=["127.0.0.1", "::1", "[::1]", "localhost"])

    blocked_origin_log =
      capture_log(fn ->
        blocked =
          conn(
            :post,
            "/mcp",
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => 2,
              "method" => "initialize",
              "params" => ProtocolTest.initialize_params()
            })
          )
          |> Map.put(:host, "localhost")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("origin", "https://app.example.com")
          |> Plug.run([app])

        assert blocked.status == 403
      end)

    assert blocked_origin_log =~ "request origin is not allowed"
    assert blocked_origin_log =~ ~s(received_host="localhost")
    assert blocked_origin_log =~ ~s(received_origins=["https://app.example.com"])

    allowed_log =
      capture_log(fn ->
        allowed =
          conn(
            :post,
            "/mcp",
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => 3,
              "method" => "initialize",
              "params" => ProtocolTest.initialize_params()
            })
          )
          |> Map.put(:host, "127.0.0.1")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("origin", "http://127.0.0.1:4000")
          |> Plug.run([app])

        assert allowed.status == 200
      end)

    refute allowed_log =~ ~s(received_origins=["http://127.0.0.1:4000"])
  end

  test "http app rejects malformed, opaque, and repeated Origin headers" do
    server_name = "http-app-origin-syntax-#{System.unique_integer([:positive])}"
    start_server!(FastestMCP.server(server_name))

    app = FastestMCP.http_app(server_name, allowed_hosts: :localhost)

    capture_log(fn ->
      for origin <- [
            "https://127.0.0.1/path",
            "https://user@127.0.0.1",
            "ftp://127.0.0.1",
            "https://127.0.0.1?query=1",
            "https://127.0.0.1#fragment",
            "https://127.0.0.1:invalid",
            "https://127.0.0.1:65536",
            "null",
            " https://127.0.0.1",
            <<255>>
          ] do
        assert origin |> origin_initialize_conn() |> Plug.run([app]) |> Map.fetch!(:status) == 403
      end

      repeated =
        "https://127.0.0.1"
        |> origin_initialize_conn()
        |> Map.update!(:req_headers, &[{"origin", "https://127.0.0.1"} | &1])
        |> Plug.run([app])

      assert repeated.status == 403
    end)

    ipv6 =
      "HTTP://[::1]:4000"
      |> origin_initialize_conn()
      |> Map.put(:host, "::1")
      |> Plug.run([app])

    assert ipv6.status == 200
  end

  test "http options reject unknown keys, naming the allowed ones" do
    server_name = "http-app-unknown-option-#{System.unique_integer([:positive])}"
    unknown = ~r/unknown keys \[:ip\], the allowed keys are: .*:bandit_options/

    assert_raise ArgumentError, unknown, fn ->
      FastestMCP.streamable_http_child_spec(server_name, port: 0, ip: {0, 0, 0, 0})
    end

    assert_raise ArgumentError, unknown, fn ->
      FastestMCP.http_app(server_name, ip: {0, 0, 0, 0})
    end
  end

  test "http options reject the removed bypass and invalid allowed hosts" do
    server_name = "http-app-host-options-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, ~r/unsafe_allow_any_host is no longer supported/, fn ->
      FastestMCP.http_app(server_name, unsafe_allow_any_host: false)
    end

    for hosts <- [
          [],
          [""],
          ["*.example.com"],
          ["https://mcp.example.com"],
          [<<255>>],
          [:localhost]
        ] do
      assert_raise ArgumentError, ~r/allowed_hosts/, fn ->
        FastestMCP.http_app(server_name, allowed_hosts: hosts)
      end
    end
  end

  test "max_body_bytes limits the request body, and a larger one gets 413" do
    server_name = unique_name("http-body-limit")
    start_server!(FastestMCP.server(server_name))

    request = ProtocolTest.modern_request(1, "server/discover")
    limit = byte_size(JSON.encode!(request))
    app = FastestMCP.http_app(server_name, max_body_bytes: limit, json_response: true)

    discover = fn payload ->
      conn(:post, "/mcp", JSON.encode!(payload))
      |> Map.put(:host, "localhost")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "server/discover")
      |> Plug.run([app])
    end

    assert discover.(request).status == 200

    too_large = discover.(put_in(request, ["params", "padding"], "x"))
    assert too_large.status == 413

    assert %{"code" => -32_600, "message" => "request body too large"} =
             JSON.decode!(too_large.resp_body)["error"]

    # A 2025-11-25 request, and a client's call through a listener.
    initialize = ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())

    legacy =
      ProtocolTest.http_post(server_name, nil, initialize,
        max_body_bytes: 10,
        json_response: true
      )

    assert legacy.status == 413

    FastestMCP.add_tool(FastestMCP.server(server_name <> "-echo"), "echo", fn args, _ctx ->
      args
    end)
    |> start_server!()

    %{url: url} = start_http!(server_name <> "-echo", max_body_bytes: 2_000)
    client = connect!(url)

    assert {:error,
            %FastestMCP.Error{code: :payload_too_large, message: "request body too large"}} =
             FastestMCP.Client.call_tool(client, "echo", %{"text" => String.duplicate("x", 3_000)})

    for invalid <- [0, -1, "1mb"] do
      assert_raise ArgumentError, ~r/max_body_bytes must be a positive integer/, fn ->
        FastestMCP.http_app(server_name, max_body_bytes: invalid)
      end
    end
  end

  test "cors answers preflight requests and adds CORS headers for the origins it allows" do
    server_name = unique_name("http-cors")
    start_server!(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["mcp.example.com"],
        cors: [origins: ["https://app.example.com", "http://localhost:6274"]]
      )

    preflight = fn origin, requested_headers ->
      conn(:options, "/mcp")
      |> Map.put(:host, "mcp.example.com")
      |> put_req_header("origin", origin)
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", requested_headers)
      |> Plug.run([app])
    end

    allowed =
      preflight.(
        "https://app.example.com",
        "Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Param-Region"
      )

    assert allowed.status == 204
    assert get_resp_header(allowed, "access-control-allow-origin") == ["https://app.example.com"]
    assert get_resp_header(allowed, "access-control-allow-methods") == ["GET, POST, DELETE"]
    assert get_resp_header(allowed, "vary") == ["origin"]
    assert [allowed_headers] = get_resp_header(allowed, "access-control-allow-headers")

    assert String.split(allowed_headers, ", ") ==
             ~w(authorization content-type accept mcp-protocol-version mcp-session-id
                mcp-method mcp-name last-event-id mcp-param-region)

    # The page can read the session id and the challenges of the responses.
    response =
      "http://localhost:6274"
      |> origin_initialize_conn()
      |> Map.put(:host, "mcp.example.com")
      |> Plug.run([app])

    assert response.status == 200
    assert get_resp_header(response, "access-control-allow-origin") == ["http://localhost:6274"]

    assert get_resp_header(response, "access-control-expose-headers") == [
             "mcp-session-id, www-authenticate"
           ]

    # Other origins get no CORS headers, and the host check rejects them.
    capture_log(fn ->
      other = preflight.("https://evil.example.com", "content-type")
      assert other.status == 403
      assert get_resp_header(other, "access-control-allow-origin") == []
    end)

    # The metadata route answers the preflight of an OAuth client in the page.
    metadata =
      conn(:options, "/.well-known/oauth-protected-resource/mcp")
      |> Map.put(:host, "mcp.example.com")
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> FastestMCP.Transport.WellKnownHTTP.call(
        FastestMCP.Transport.WellKnownHTTP.init(
          server_name: server_name,
          allowed_hosts: ["mcp.example.com"],
          cors: [origins: ["https://app.example.com"]]
        )
      )

    assert metadata.status == 204
    assert get_resp_header(metadata, "access-control-allow-origin") == ["https://app.example.com"]

    for origins <- [
          [],
          ["*"],
          ["https://*.example.com"],
          ["https://app.example.com/path"],
          ["app.example.com"],
          "https://app.example.com"
        ] do
      assert_raise ArgumentError, ~r/cors/, fn ->
        FastestMCP.http_app(server_name, cors: [origins: origins])
      end
    end
  end

  test "allowed_hosts and base_url can name a function that runs on each request" do
    server_name = unique_name("http-runtime-hosts")
    on_exit(fn -> :persistent_term.erase({__MODULE__, server_name}) end)
    :persistent_term.put({__MODULE__, server_name}, "one.example.com")

    FastestMCP.server(server_name,
      protected_resource: [
        resource: "https://two.example.com/mcp",
        authorization_servers: ["https://auth.example.com"]
      ],
      auth: fn input, _ctx -> {:ok, %{audiences: [input["expected_resource"]]}} end
    )
    |> start_server!()

    # A proxy in front terminates TLS: the base URL names the public URL.
    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: {__MODULE__, :runtime_hosts, [server_name]},
        base_url: {__MODULE__, :runtime_base_url, []}
      )

    initialize = fn host ->
      "http://#{host}"
      |> origin_initialize_conn()
      |> Map.put(:host, host)
      |> put_req_header("authorization", "Bearer token")
      |> Plug.run([app])
    end

    assert initialize.("one.example.com").status == 200

    :persistent_term.put({__MODULE__, server_name}, "two.example.com")

    capture_log(fn ->
      assert initialize.("one.example.com").status == 403
    end)

    assert initialize.("two.example.com").status == 200

    assert_raise ArgumentError, ~r/allowed_hosts/, fn ->
      FastestMCP.http_app(server_name, allowed_hosts: {__MODULE__, :runtime_hosts})
    end
  end

  def runtime_hosts(server_name), do: [:persistent_term.get({__MODULE__, server_name})]

  def runtime_base_url, do: "https://two.example.com"

  test "http app applies multiple middleware in order" do
    server_name = "http-app-order-" <> Integer.to_string(System.unique_integer([:positive]))
    start_server!(FastestMCP.server(server_name))

    app =
      FastestMCP.http_app(server_name,
        allowed_hosts: ["www.example.com"],
        middleware: [
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-first-header", "first"))
            |> next.()
          end,
          fn conn, next ->
            conn
            |> register_before_send(&put_resp_header(&1, "x-second-header", "second"))
            |> next.()
          end
        ],
        routes: [
          {"GET", "/test", fn conn -> json(conn, 200, %{message: "ok"}) end}
        ]
      )

    response = conn(:get, "/test") |> Plug.run([app])

    assert response.status == 200
    assert get_resp_header(response, "x-first-header") == ["first"]
    assert get_resp_header(response, "x-second-header") == ["second"]
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end

  defp origin_initialize_conn(origin) do
    conn(
      :post,
      "/mcp",
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "initialize",
        "params" => ProtocolTest.initialize_params()
      })
    )
    |> Map.put(:host, "127.0.0.1")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("origin", origin)
  end

  defp initialize_app(app) do
    initialize_response =
      app_request(
        app,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      )

    assert initialize_response.status == 200
    [session_id] = get_resp_header(initialize_response, "mcp-session-id")

    initialized_response =
      app_request(
        app,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized_response.status == 202
    session_id
  end

  defp app_request(app, payload, session_id \\ nil) do
    conn(:post, "/mcp", JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> maybe_put_session_headers(session_id)
    |> Plug.run([app])
  end

  defp maybe_put_session_headers(conn, nil), do: conn

  defp maybe_put_session_headers(conn, session_id) do
    conn
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
  end
end
