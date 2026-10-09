defmodule FastestMCP.ClientLifecycleTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Test.ClientProbe

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Error

  defmodule LifecyclePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      test_pid = Keyword.fetch!(opts, :test_pid)
      mode = Keyword.get(opts, :mode, :block_initialized)

      case request do
        %{"id" => id, "method" => "initialize"} ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "serverInfo" => %{"name" => "lifecycle-test", "version" => "1.0.0"}
            }
          }

          conn
          |> put_resp_header("mcp-session-id", "lifecycle-session")
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(response))

        %{"method" => "notifications/initialized"} when mode == :fail_initialized ->
          send_resp(conn, 500, "initialization notification failed")

        %{"method" => "notifications/initialized"} ->
          send(test_pid, {:initialized_notification_received, self()})

          receive do
            :release_initialized -> send_resp(conn, 202, "")
          after
            2_000 -> send_resp(conn, 500, "test release timed out")
          end

        %{"id" => id, "method" => "ping"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}))
      end
    end
  end

  defmodule DiscoveryPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      test_pid = Keyword.fetch!(opts, :test_pid)

      case request do
        %{"id" => id, "method" => "server/discover"} ->
          if Keyword.get(opts, :block_discovery, false) do
            send(test_pid, {:discovery_request, self()})

            receive do
              :release_discovery -> :ok
            end
          end

          reply(conn, id, %{
            "resultType" => "complete",
            "supportedVersions" => Keyword.get(opts, :supported_versions, ["2026-07-28"]),
            "capabilities" => %{},
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => %{
              "io.modelcontextprotocol/serverInfo" => %{
                "name" => "lifecycle-discovery-test",
                "version" => "1.0.0"
              }
            }
          })

        %{"id" => id, "method" => "example/block"} ->
          send(test_pid, {:blocking_request, self()})

          receive do
            :release_request -> reply(conn, id, %{"resultType" => "complete"})
          end
      end
    end

    defp reply(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  defmodule LegacySessionPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)

      case conn.method do
        "POST" ->
          handle_post(conn, state)

        "DELETE" ->
          delete = %{
            session: header(conn, "mcp-session-id"),
            authorization: header(conn, "authorization")
          }

          Agent.update(state, &Map.update!(&1, :deletes, fn deletes -> [delete | deletes] end))
          send_resp(conn, 200, "")

        _method ->
          send_resp(conn, 405, "")
      end
    end

    defp handle_post(conn, state) do
      {:ok, body, conn} = read_body(conn)
      message = JSON.decode!(body)
      post = {message["method"], header(conn, "authorization")}
      Agent.update(state, &Map.update!(&1, :posts, fn posts -> [post | posts] end))

      case message do
        %{"method" => "initialize", "id" => id} ->
          conn
          |> put_resp_header("mcp-session-id", "legacy-session")
          |> reply(id, %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "legacy-session", "version" => "1.0.0"}
          })

        %{"method" => "notifications/initialized"} ->
          send_resp(conn, 202, "")

        %{"id" => id} ->
          reply(conn, id, %{})
      end
    end

    defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

    defp reply(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  test "initialization has one owner and completes only after initialized is accepted" do
    client = start_client(:block_initialized)

    assert ClientProbe.phase(client) == :new

    before_init = capture_error(fn -> Client.ping!(client) end)
    assert before_init.code == :invalid_request
    assert before_init.details.lifecycle_state == :new

    initializer = Task.async(fn -> capture_result(fn -> Client.initialize!(client) end) end)

    assert_receive {:initialized_notification_received, notification_pid}, 1_000
    assert Task.yield(initializer, 0) == nil

    duplicate = Task.async(fn -> capture_result(fn -> Client.initialize!(client) end) end)
    initializing_ping = Task.async(fn -> capture_result(fn -> Client.ping!(client) end) end)

    assert Task.yield(duplicate, 0) == nil
    assert Task.yield(initializing_ping, 0) == nil
    # The duplicate's call must reach the client while it is still initializing.
    assert_eventually(fn ->
      Process.info(duplicate.pid, :current_function) == {:current_function, {:gen, :do_call, 4}}
    end)

    send(notification_pid, :release_initialized)

    assert {:error, %Error{code: :invalid_request} = duplicate_error} =
             Task.await(duplicate, 1_000)

    assert duplicate_error.details.lifecycle_state == :initializing
    assert {:ok, %{}} = Task.await(initializing_ping, 1_000)

    assert {:ok, %{"protocolVersion" => version}} = Task.await(initializer, 1_000)
    assert version == "2025-11-25"
    assert ClientProbe.phase(client) == :initialized
    assert Client.info!(client).initialize_result["protocolVersion"] == version

    after_init = capture_error(fn -> Client.initialize!(client) end)
    assert after_init.code == :invalid_request
    assert after_init.details.lifecycle_state == :initialized
  end

  test "a failed initialized notification makes initialization terminal" do
    client = start_client(:fail_initialized)

    error = capture_error(fn -> Client.initialize!(client) end)
    assert error.code in [:bad_request, :internal_error]
    assert ClientProbe.phase(client) == :failed
    assert Client.info!(client).initialize_result == nil

    retry_error = capture_error(fn -> Client.initialize!(client) end)
    assert retry_error.code == :invalid_request
    assert retry_error.details.lifecycle_state == :failed

    request_error = capture_error(fn -> Client.ping!(client) end)
    assert request_error.code == :invalid_request
    assert request_error.details.lifecycle_state == :failed
  end

  test "supervised named clients are ready before start returns and pin old handles" do
    server_name = "supervised-client-server-#{System.unique_integer([:positive])}"
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
    |> start_server!()

    pid =
      start_supervised!(
        {Client,
         target: {:in_process, server_name}, name: client_name, protocol_version: "2026-07-28"}
      )

    assert Client.ready?(client_name)
    assert :ok = Client.await_ready!(client_name, 100)
    assert %{items: [%{"name" => "echo"}]} = Client.list_tools!(client_name)

    old_client = %Client{pid: pid}
    Process.exit(pid, :kill)

    assert :ok = Client.await_ready!(client_name, 2_000)
    replacement = GenServer.whereis(client_name)
    assert is_pid(replacement)
    refute replacement == pid

    assert_raise Error, ~r/not running/, fn -> Client.list_tools!(old_client) end
    assert %{items: [%{"name" => "echo"}]} = Client.list_tools!(client_name)
  end

  test "manual negotiation releases readiness waiters" do
    server_name = "manual-ready-server-#{System.unique_integer([:positive])}"
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    start_server!(FastestMCP.server(server_name))

    _pid =
      start_supervised!(
        {Client,
         target: {:in_process, server_name},
         name: client_name,
         auto_initialize: false,
         protocol_version: "2026-07-28"}
      )

    refute Client.ready?(client_name)

    assert_raise Error, ~r/did not become ready/, fn ->
      Client.await_ready!(client_name, 1)
    end

    assert_eventually(fn -> ClientProbe.readiness_waiters(client_name) == %{} end)

    waiter = Task.async(fn -> Client.await_ready!(client_name, 1_000) end)
    assert Task.yield(waiter, 0) == nil

    assert %{"supportedVersions" => supported_versions} = Client.discover!(client_name)
    assert "2026-07-28" in supported_versions
    assert :ok = Task.await(waiter, 1_000)
    assert Client.ready?(client_name)
  end

  test "Registry names and explicit child ids support multiple supervised clients" do
    server_name = "registry-client-server-#{System.unique_integer([:positive])}"
    registry = Module.concat(__MODULE__, ClientRegistry)

    start_server!(FastestMCP.server(server_name))

    _registry = start_supervised!({Registry, keys: :unique, name: registry})
    registry_name = {:via, Registry, {registry, :primary}}

    _named =
      start_supervised!(
        {Client,
         target: {:in_process, server_name},
         name: registry_name,
         id: :registry_mcp_client,
         protocol_version: "2026-07-28"}
      )

    unnamed =
      start_supervised!(
        {Client,
         target: {:in_process, server_name},
         id: :unnamed_mcp_client,
         protocol_version: "2026-07-28"}
      )

    assert Client.ready?(registry_name)
    assert Client.ready?(unnamed)
    assert Client.info!(registry_name).protocol_version == "2026-07-28"
    assert Client.info!(%Client{pid: unnamed}).protocol_version == "2026-07-28"
  end

  test "one discovery owner excludes concurrent attempts" do
    %{url: url} = serve!({DiscoveryPlug, test_pid: self(), block_discovery: true})

    client =
      connect!(url,
        auto_initialize: false,
        protocol_version: "2026-07-28"
      )

    owner = Task.async(fn -> Client.discover!(client) end)
    assert_receive {:discovery_request, request_pid}, 1_000

    error = capture_error(fn -> Client.discover!(client) end)
    assert error.code == :invalid_request
    assert error.message =~ "already in progress"

    send(request_pid, :release_discovery)
    assert %{"supportedVersions" => ["2026-07-28"]} = Task.await(owner, 1_000)
    assert Client.ready?(client)
  end

  test "failed supervised startup releases its name without changing trap-exit state" do
    %{url: url} = serve!({DiscoveryPlug, test_pid: self(), supported_versions: []})
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    {:trap_exit, trap_exit_before} = Process.info(self(), :trap_exit)

    assert {:error, %Error{code: :unsupported_protocol_version}} =
             Client.start_link(
               target: url,
               name: client_name,
               protocol_version: "2026-07-28"
             )

    assert GenServer.whereis(client_name) == nil
    assert {:trap_exit, ^trap_exit_before} = Process.info(self(), :trap_exit)
  end

  test "a client crash terminates its supervised request workers" do
    %{url: url} = serve!({DiscoveryPlug, test_pid: self()})
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    client_pid =
      start_supervised!({Client, target: url, name: client_name, protocol_version: "2026-07-28"})

    _request = Client.request_async!(client_name, "example/block", %{}, timeout_ms: :infinity)
    assert_receive {:blocking_request, request_pid}, 1_000

    [%{worker: worker_pid}] = Map.values(ClientProbe.requests(client_pid))
    worker_supervisor = ClientProbe.worker_supervisor(client_pid)
    assert Process.alive?(worker_pid)
    assert Process.alive?(worker_supervisor)
    worker = Process.monitor(worker_pid)
    supervisor = Process.monitor(worker_supervisor)

    Process.exit(client_pid, :kill)

    assert_receive {:DOWN, ^worker, :process, ^worker_pid, _reason}
    assert_receive {:DOWN, ^supervisor, :process, ^worker_supervisor, _reason}
    send(request_pid, :release_request)
  end

  test "disconnect deletes the HTTP session with OAuth credentials and leaves the owner alive" do
    %{resource: resource, state: state} = start_legacy_session_server()
    oauth = client_credentials_oauth(resource)

    assert {:exited, :normal, :ok} =
             isolated(fn ->
               client = Client.connect!(resource, protocol_version: "2025-11-25", oauth: oauth)
               oauth_pid = ClientProbe.oauth_pid(client)
               assert {:ok, "Bearer token-one"} = OAuth.authorize(oauth_pid, resource)
               Client.disconnect(client)
             end)

    assert [%{session: "legacy-session", authorization: "Bearer token-one"}] =
             Agent.get(state, & &1.deletes)
  end

  test "supervised shutdown runs client cleanup and deletes the HTTP session" do
    %{resource: resource, state: state} = start_legacy_session_server()

    start_supervised!({Client, target: resource, protocol_version: "2025-11-25"})
    :ok = stop_supervised(Client)

    assert [%{session: "legacy-session"}] = Agent.get(state, & &1.deletes)
  end

  test "set_auth replaces every credential of the connection" do
    %{resource: resource, state: state} = start_legacy_session_server()
    client = connect!(resource, protocol_version: "2025-11-25", access_token: "abc")

    assert :ok = Client.set_auth(client, [])
    assert {:ok, _result} = Client.ping(client)
    assert :ok = Client.set_auth(client, access_token: "t2")
    assert {:ok, _result} = Client.ping(client)

    assert [{"ping", nil}, {"ping", "Bearer t2"}] =
             state
             |> Agent.get(&Enum.reverse(&1.posts))
             |> Enum.filter(&match?({"ping", _}, &1))

    assert_raise ArgumentError, ~r/unknown keys \[:token\]/, fn ->
      Client.set_auth(client, token: "t3")
    end

    assert_raise ArgumentError, "access_token must be a string", fn ->
      Client.set_auth(client, access_token: 3)
    end
  end

  test "connect returns an init error without killing a caller that does not trap exits" do
    # The named server is absent, so opening the transport fails inside init/1.
    assert {:exited, :normal, {:error, %Error{code: :bad_request}}} =
             isolated(fn -> Client.connect({:in_process, unique_name("absent")}) end)
  end

  test "OAuth start_link returns configuration errors without killing the caller" do
    assert {:exited, :normal,
            {:error, %OAuth.Error{stage: :configuration, reason: :https_required}}} =
             isolated(fn ->
               OAuth.start_link(
                 redirect_uri: "http://127.0.0.1:8765/callback",
                 registration: {:pre_registered, client_id: "test-client"},
                 authorization_handler: fn _request -> {:error, :unused} end,
                 authorization_server: "http://127.0.0.1:8766/tenant",
                 requester: fn _method, _url, _opts -> {:error, :unused} end
               )
             end)
  end

  defp start_client(mode) do
    %{url: url} = serve!({LifecyclePlug, test_pid: self(), mode: mode})

    client =
      connect!(url,
        auto_initialize: false,
        protocol_version: "2025-11-25"
      )

    client
  end

  defp capture_result(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end

  defp capture_error(fun) do
    assert {:error, %Error{} = error} = capture_result(fun)
    error
  end

  defp start_legacy_session_server do
    state = start_supervised!({Agent, fn -> %{deletes: [], posts: []} end})

    %{url: url} = serve!({LegacySessionPlug, state: state})
    %{resource: url, state: state}
  end

  defp client_credentials_oauth(resource) do
    issuer = "https://auth.example.com"
    token_endpoint = issuer <> "/token"

    requester = fn
      :get, url, _opts ->
        if String.contains?(url, "oauth-protected-resource") do
          json_response(%{
            "resource" => resource,
            "authorization_servers" => [issuer],
            "scopes_supported" => ["files:read"]
          })
        else
          json_response(%{
            "issuer" => issuer,
            "token_endpoint" => token_endpoint,
            "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
          })
        end

      :post, ^token_endpoint, _opts ->
        json_response(%{
          "access_token" => "token-one",
          "token_type" => "Bearer",
          "expires_in" => 3_600,
          "scope" => "files:read"
        })
    end

    [
      grant:
        {:client_credentials,
         client_id: "machine-client",
         client_secret: "secret",
         token_endpoint_auth_method: "client_secret_basic",
         issuer: issuer},
      requester: requester
    ]
  end

  defp json_response(body),
    do: {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(body)}

  # Runs `fun` in a process that does not trap exits and reports how it ended.
  defp isolated(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:isolated_result, self(), fun.()}) end)

    result =
      receive do
        {:isolated_result, ^pid, value} -> value
      after
        10_000 -> :no_result
      end

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:exited, reason, result}
    after
      10_000 -> {:still_running, result}
    end
  end
end
