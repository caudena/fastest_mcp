defmodule FastestMCP.Case do
  @moduledoc """
  Shared ExUnit case for FastestMCP tests.

  `use FastestMCP.Case` (optionally with `async: true`) imports the helpers
  below and aliases `FastestMCP.TestSupport.ProtocolTestHelper` as
  `ProtocolTest`.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  using do
    quote do
      import FastestMCP.Case
      alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
    end
  end

  @doc "Returns `prefix` suffixed with a unique positive integer."
  def unique_name(prefix \\ "test"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc """
  Returns the runtime snapshot of a server named `server_name` that is not
  running, for building contexts with `FastestMCP.Context.new/2`.
  """
  def test_runtime(server_name),
    do: %FastestMCP.ServerRuntime{server: FastestMCP.server(server_name)}

  @doc "Starts `server` for the current test and stops it when the test exits."
  def start_server!(%FastestMCP.Server{} = server, opts \\ []) do
    assert {:ok, _pid} = FastestMCP.start_server(server, opts)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
    server
  end

  @doc """
  Connects a client with `FastestMCP.Client.connect/2` and disconnects it when
  the test exits.
  """
  def connect!(target, opts \\ []) do
    assert {:ok, client} = FastestMCP.Client.connect(target, opts)
    on_exit(fn -> FastestMCP.Client.disconnect!(client) end)
    client
  end

  @doc """
  Starts the state of a stateful middleware for the current test, as a server
  would, and returns the middleware attached to it.
  """
  def start_middleware!(%module{} = middleware) do
    pid = start_supervised!(Supervisor.child_spec(module.child_spec(middleware), id: make_ref()))
    FastestMCP.Middleware.attach(middleware, pid)
  end

  @doc """
  Serves `plug` over HTTP on a random loopback port until the test exits.

  `path` (default `"/mcp"`) is appended to the returned URL; other options are
  passed to Bandit. Returns the listener `pid`, its `port`, and the `url`. The
  listener is not restarted when a test stops it.
  """
  def serve!(plug, opts \\ []) do
    {path, opts} = Keyword.pop(opts, :path, "/mcp")

    # A short shutdown timeout keeps a lingering connection from delaying the
    # end of the test by Bandit's default 15 s.
    bandit_opts =
      Keyword.merge(
        [
          plug: plug,
          scheme: :http,
          ip: :loopback,
          port: 0,
          startup_log: false,
          thousand_island_options: [shutdown_timeout: 100]
        ],
        opts
      )

    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, bandit_opts}, id: make_ref(), restart: :temporary)
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, port: port, url: "http://127.0.0.1:#{port}#{path}"}
  end

  @doc """
  Serves the running server `server_name` over HTTP with `serve!/2`.

  Options are passed to `FastestMCP.Transport.HTTPApp` (`path` defaults to
  `"/mcp"`).
  """
  def start_http!(server_name, opts \\ []) do
    opts = Keyword.merge([server_name: server_name, path: "/mcp"], opts)
    serve!({FastestMCP.Transport.HTTPApp, opts}, path: opts[:path])
  end

  @doc """
  Sends the telemetry `events` to the test process as
  `{:telemetry, event, measurements, metadata}` until the test exits.
  """
  def attach_telemetry(events) do
    handler_id = make_ref()
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.send_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def send_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  @doc """
  Waits until task `task_id` of `server_name` has `status` and returns it.
  `opts` are passed to `FastestMCP.fetch_task!/3`.
  """
  def await_task_status(server_name, task_id, status, opts \\ []) do
    assert_eventually(fn ->
      task = FastestMCP.fetch_task!(server_name, task_id, opts)
      task.status == status && task
    end)
  end

  @doc "Counts the session processes registered for `server_name`."
  def registered_sessions(server_name) do
    Registry.count_select(FastestMCP.Registry, [
      {{{:session, to_string(server_name), :_}, :_, :_}, [], [true]}
    ])
  end

  @doc """
  Polls `fun` every 10 ms until it returns a truthy value and returns that
  value, or fails the test after `timeout_ms`.
  """
  def assert_eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      value = fun.() ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end
end
