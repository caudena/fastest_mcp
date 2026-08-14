defmodule FastestMCP.ClientLifecycleTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastestMCP.Client
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

  test "initialization has one owner and completes only after initialized is accepted" do
    client = start_client(:block_initialized)

    assert Client.lifecycle_state(client) == :new

    before_init = capture_error(fn -> Client.ping(client) end)
    assert before_init.code == :invalid_request
    assert before_init.details.lifecycle_state == :new

    initializer = Task.async(fn -> capture_result(fn -> Client.initialize(client) end) end)

    assert_receive {:initialized_notification_received, notification_pid}, 1_000
    assert Task.yield(initializer, 0) == nil

    duplicate = Task.async(fn -> capture_result(fn -> Client.initialize(client) end) end)
    initializing_ping = Task.async(fn -> capture_result(fn -> Client.ping(client) end) end)

    assert Task.yield(duplicate, 0) == nil
    assert Task.yield(initializing_ping, 0) == nil

    send(notification_pid, :release_initialized)

    assert {:error, %Error{code: :invalid_request} = duplicate_error} =
             Task.await(duplicate, 1_000)

    assert duplicate_error.details.lifecycle_state == :initializing
    assert {:ok, %{}} = Task.await(initializing_ping, 1_000)

    assert {:ok, %{"protocolVersion" => version}} = Task.await(initializer, 1_000)
    assert version == "2025-11-25"
    assert Client.lifecycle_state(client) == :initialized
    assert Client.initialize_result(client)["protocolVersion"] == version

    after_init = capture_error(fn -> Client.initialize(client) end)
    assert after_init.code == :invalid_request
    assert after_init.details.lifecycle_state == :initialized
  end

  test "a failed initialized notification makes initialization terminal" do
    client = start_client(:fail_initialized)

    error = capture_error(fn -> Client.initialize(client) end)
    assert error.code in [:bad_request, :internal_error]
    assert Client.lifecycle_state(client) == :failed
    assert Client.initialize_result(client) == nil

    retry_error = capture_error(fn -> Client.initialize(client) end)
    assert retry_error.code == :invalid_request
    assert retry_error.details.lifecycle_state == :failed

    request_error = capture_error(fn -> Client.ping(client) end)
    assert request_error.code == :invalid_request
    assert request_error.details.lifecycle_state == :failed
  end

  test "supervised named clients are ready before start returns and pin old handles" do
    server_name = "supervised-client-server-#{System.unique_integer([:positive])}"
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    pid =
      start_supervised!(
        {Client,
         target: {:in_process, server_name}, name: client_name, protocol_version: "2026-07-28"}
      )

    assert Client.ready?(client_name)
    assert :ok = Client.await_ready(client_name, 100)
    assert %{items: [%{"name" => "echo"}]} = Client.list_tools(client_name)

    old_client = %Client{pid: pid}
    Process.exit(pid, :kill)

    assert :ok = Client.await_ready(client_name, 2_000)
    replacement = GenServer.whereis(client_name)
    assert is_pid(replacement)
    refute replacement == pid

    assert_raise Error, ~r/not running/, fn -> Client.list_tools(old_client) end
    assert %{items: [%{"name" => "echo"}]} = Client.list_tools(client_name)
  end

  test "manual negotiation releases readiness waiters" do
    server_name = "manual-ready-server-#{System.unique_integer([:positive])}"
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

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
      Client.await_ready(client_name, 1)
    end

    Process.sleep(10)
    assert :sys.get_state(GenServer.whereis(client_name)).readiness_waiters == %{}

    waiter = Task.async(fn -> Client.await_ready(client_name, 1_000) end)
    assert Task.yield(waiter, 0) == nil

    assert %{"supportedVersions" => supported_versions} = Client.discover(client_name)
    assert "2026-07-28" in supported_versions
    assert :ok = Task.await(waiter, 1_000)
    assert Client.ready?(client_name)
  end

  test "Registry names and explicit child ids support multiple supervised clients" do
    server_name = "registry-client-server-#{System.unique_integer([:positive])}"
    registry = Module.concat(__MODULE__, ClientRegistry)

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

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
    assert Client.protocol_version(registry_name) == "2026-07-28"
    assert Client.protocol_version(%Client{pid: unnamed}) == "2026-07-28"
  end

  test "one discovery owner excludes concurrent attempts" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {DiscoveryPlug, test_pid: self(), block_discovery: true}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        auto_initialize: false,
        protocol_version: "2026-07-28"
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    owner = Task.async(fn -> Client.discover(client) end)
    assert_receive {:discovery_request, request_pid}, 1_000

    error = capture_error(fn -> Client.discover(client) end)
    assert error.code == :invalid_request
    assert error.message =~ "already in progress"

    send(request_pid, :release_discovery)
    assert %{"supportedVersions" => ["2026-07-28"]} = Task.await(owner, 1_000)
    assert Client.ready?(client)
  end

  test "failed supervised startup releases its name without changing trap-exit state" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {DiscoveryPlug, test_pid: self(), supported_versions: []}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    {:trap_exit, trap_exit_before} = Process.info(self(), :trap_exit)

    assert {:error, %Error{code: :unsupported_protocol_version}} =
             Client.start_link(
               target: "http://127.0.0.1:#{port}/mcp",
               name: client_name,
               protocol_version: "2026-07-28"
             )

    assert GenServer.whereis(client_name) == nil
    assert {:trap_exit, ^trap_exit_before} = Process.info(self(), :trap_exit)
  end

  test "a client crash terminates its supervised request workers" do
    bandit =
      start_supervised!({Bandit, plug: {DiscoveryPlug, test_pid: self()}, scheme: :http, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client_name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    client_pid =
      start_supervised!(
        {Client,
         target: "http://127.0.0.1:#{port}/mcp", name: client_name, protocol_version: "2026-07-28"}
      )

    _request = Client.request_async(client_name, "example/block", %{}, timeout_ms: :infinity)
    assert_receive {:blocking_request, request_pid}, 1_000

    state = :sys.get_state(client_pid)
    [%{worker_pid: worker_pid}] = Map.values(state.in_flight)
    worker_supervisor = state.worker_supervisor
    assert Process.alive?(worker_pid)
    assert Process.alive?(worker_supervisor)

    Process.exit(client_pid, :kill)

    refute_eventually_alive(worker_pid)
    refute_eventually_alive(worker_supervisor)
    send(request_pid, :release_request)
  end

  defp start_client(mode) do
    bandit =
      start_supervised!(
        {Bandit, plug: {LifecyclePlug, test_pid: self(), mode: mode}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        auto_initialize: false,
        protocol_version: "2025-11-25"
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

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

  defp refute_eventually_alive(pid, attempts \\ 50)

  defp refute_eventually_alive(pid, 0), do: refute(Process.alive?(pid))

  defp refute_eventually_alive(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      refute_eventually_alive(pid, attempts - 1)
    else
      :ok
    end
  end
end
