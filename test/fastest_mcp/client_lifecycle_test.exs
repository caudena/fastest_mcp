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
              "protocolVersion" => FastestMCP.Protocol.current_version(),
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
    assert version == FastestMCP.Protocol.current_version()
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

  defp start_client(mode) do
    bandit =
      start_supervised!(
        {Bandit, plug: {LifecyclePlug, test_pid: self(), mode: mode}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp", auto_initialize: false)

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
end
