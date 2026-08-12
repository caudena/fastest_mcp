defmodule FastestMCP.TestSupport.ProtocolTestHelper do
  @moduledoc false

  alias FastestMCP.Protocol
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP

  @version Protocol.current_version()
  @post_accept "application/json, text/event-stream"

  def protocol_version, do: @version

  def initialize_params(overrides \\ %{}) do
    Map.merge(
      %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "FastestMCP test client", "version" => "1.0.0"}
      },
      Map.new(overrides)
    )
  end

  def initialize_session(server_name, session_id, overrides \\ %{}) do
    params = initialize_params(overrides)
    {:ok, runtime} = ServerRuntime.fetch(server_name)

    initialize_result =
      FastestMCP.initialize(server_name, params,
        transport: :stdio,
        session_id: session_id,
        request_metadata: %{
          jsonrpc_envelope: jsonrpc_request(1, "initialize", params)
        },
        wire: true
      )

    {:ok, _pid} =
      SessionSupervisor.ensure_session(runtime.session_supervisor, server_name, session_id)

    :ok =
      Session.begin_initialization(
        server_name,
        session_id,
        params["protocolVersion"],
        params["capabilities"],
        params["clientInfo"],
        :unbound,
        Map.get(initialize_result, "capabilities", %{})
      )

    :ok = Session.mark_initialized(server_name, session_id)
    session_id
  end

  def initialize_stdio(server_name, opts \\ []) do
    connection_id = Keyword.get(opts, :connection_id, make_ref())
    dispatch_opts = opts |> Keyword.delete(:params) |> Keyword.put(:connection_id, connection_id)

    initialize_response =
      Stdio.dispatch(
        server_name,
        jsonrpc_request(1, "initialize", initialize_params(Keyword.get(opts, :params, %{}))),
        dispatch_opts
      )

    :no_response =
      Stdio.dispatch(
        server_name,
        jsonrpc_notification("notifications/initialized", %{}),
        dispatch_opts
      )

    {connection_id, initialize_response}
  end

  def stdio_request(server_name, connection_id, id, method, params \\ %{}, opts \\ []) do
    Stdio.dispatch(
      server_name,
      jsonrpc_request(id, method, params),
      Keyword.put(opts, :connection_id, connection_id)
    )
  end

  def http_initialize(server_name, call_opts \\ [], params \\ %{}) do
    path = Keyword.get(call_opts, :path, "/mcp")
    headers = Keyword.get(call_opts, :headers, [])
    call_opts = transport_opts(call_opts, server_name)

    response =
      :post
      |> Plug.Test.conn(
        path,
        JSON.encode!(jsonrpc_request(1, "initialize", initialize_params(params)))
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", @post_accept)
      |> Map.put(:host, "localhost")
      |> put_headers(headers)
      |> StreamableHTTP.call(call_opts)

    [session_id] = Plug.Conn.get_resp_header(response, "mcp-session-id")
    {session_id, response}
  end

  def http_mark_initialized(server_name, session_id, call_opts \\ []) do
    http_post(
      server_name,
      session_id,
      jsonrpc_notification("notifications/initialized", %{}),
      call_opts
    )
  end

  def initialize_http(server_name, call_opts \\ [], params \\ %{}) do
    {session_id, initialize_response} = http_initialize(server_name, call_opts, params)
    initialized_response = http_mark_initialized(server_name, session_id, call_opts)
    {session_id, initialize_response, initialized_response}
  end

  def http_request(server_name, session_id, id, method, params \\ %{}, call_opts \\ []) do
    http_post(server_name, session_id, jsonrpc_request(id, method, params), call_opts)
  end

  def http_post(server_name, session_id, payload, call_opts \\ []) do
    path = Keyword.get(call_opts, :path, "/mcp")
    headers = Keyword.get(call_opts, :headers, [])
    call_opts = transport_opts(call_opts, server_name)

    :post
    |> Plug.Test.conn(path, JSON.encode!(payload))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", @post_accept)
    |> Map.put(:host, "localhost")
    |> maybe_put_header("mcp-session-id", session_id)
    |> maybe_put_header("mcp-protocol-version", @version)
    |> put_headers(headers)
    |> StreamableHTTP.call(call_opts)
  end

  def jsonrpc_request(id, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  def jsonrpc_notification(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp maybe_put_header(conn, _key, nil), do: conn
  defp maybe_put_header(conn, key, value), do: Plug.Conn.put_req_header(conn, key, value)

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, to_string(key), to_string(value))
    end)
  end

  defp transport_opts(opts, server_name) do
    opts
    |> Keyword.delete(:headers)
    |> Keyword.put_new(:json_response, true)
    |> Keyword.put(:server_name, server_name)
  end
end
