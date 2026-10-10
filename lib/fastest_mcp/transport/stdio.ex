defmodule FastestMCP.Transport.Stdio do
  @moduledoc """
  JSON-lines stdio transport.

  `serve/4` reads one JSON-RPC message per line and writes the responses and
  notifications, one per line, until the input ends. Given a
  `%FastestMCP.Server{}`, it starts that server for the connection
  (`:server_options` are its runtime options) and stops it at the end; given
  the name of a running server, it serves that server, and raises
  `ArgumentError` when none is running. While it writes to stdout, Logger
  output and the output of the server's workers go to stderr. `:auth_input` is
  the input that the server's authenticator receives for every request, as for
  an in-process call.

  A server module serves itself with its `serve_stdio/1`; see
  `FastestMCP.ServerModule.serve_stdio/2`.
  """

  alias FastestMCP.Error
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.Transport.Dispatch
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Stdio.Connection
  alias FastestMCP.Transport.Stdio.OutputGuard
  alias FastestMCP.Transport.StdioAdapter

  @doc """
  Handles one message (a JSON line or a decoded map) for a running server:
  returns the response envelope, or `:no_response` for a notification.
  """
  def dispatch(server_name, message, opts \\ []) do
    with {:ok, message} <- decode_input(message),
         {:ok, request} <- StdioAdapter.decode(message, opts) do
      outcome =
        case ServerRuntime.fetch_running(server_name) do
          {:ok, runtime} ->
            outcome = Dispatch.run(runtime, request, opts)
            Dispatch.after_delivery(runtime, request, outcome)
            outcome

          error ->
            error
        end

      Dispatch.envelope(outcome, request) || :no_response
    else
      {:error, %Error{} = error} -> StdioAdapter.decode_error(error) || :no_response
    end
  end

  @doc "Serves `server_or_name` over `input_device` and `output_device` until the input ends."
  def serve(
        server_or_name,
        input_device \\ IO.binstream(:stdio, :line),
        output_device \\ :stdio,
        opts \\ []
      )

  def serve(%Server{} = server, input_device, output_device, opts) do
    {server_opts, opts} = Keyword.pop(opts, :server_options, [])

    unless Keyword.keyword?(server_opts) do
      raise ArgumentError, ":server_options must be a keyword list"
    end

    start_application!(:fastest_mcp)

    # The connection's start blocks in the server's lifespans, which do not
    # notice this process exit; the output guard aborts that start.
    :ok = OutputGuard.acquire(starting: server.name)

    try do
      serve_connection({server, Config.protect(server_opts)}, input_device, output_device, opts)
    after
      OutputGuard.release()
    end
  end

  def serve(server_name, input_device, output_device, opts),
    do: serve_connection(server_name, input_device, output_device, opts)

  @doc false
  # Runs `fun` with Logger output moved from stdout to stderr, as while
  # serving, for an entry point that starts applications before it serves.
  # `serve/4` of a server definition in `fun` releases the move when it ends.
  def with_stdout_isolated(fun) do
    start_application!(:fastest_mcp)

    with {:error, reason} <- OutputGuard.acquire(logger: true),
         do: raise(ArgumentError, start_error(nil, {:logger_isolation, reason}))

    try do
      fun.()
    after
      OutputGuard.release()
    end
  end

  @doc false
  def start_application!(application) do
    case Application.ensure_all_started(application) do
      {:ok, _applications} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(application)}: #{inspect(reason)}"
    end
  end

  defp serve_connection(server, input_device, output_device, opts) do
    args = %{
      owner: self(),
      server: server,
      input: input_device,
      output: output_device,
      opts: Keyword.put_new_lazy(opts, :connection_id, &make_ref/0)
    }

    case Connection.start_monitor(args) do
      {:ok, {connection, monitor}} ->
        receive do
          {:DOWN, ^monitor, :process, ^connection, :normal} -> :ok
          {:DOWN, ^monitor, :process, ^connection, {:shutdown, reason}} -> exit(reason)
          {:DOWN, ^monitor, :process, ^connection, reason} -> exit(reason)
        end

      {:error, {:shutdown, reason}} ->
        raise ArgumentError, start_error(server, reason)
    end
  end

  defp start_error(_server, {:logger_isolation, reason}) do
    "cannot start stdio transport safely because Logger stdout isolation failed: " <>
      "#{inspect(reason)}. Configure stdout Logger handlers to use " <>
      ":standard_error or another non-stdout destination"
  end

  defp start_error(_server, {:runtime_isolation, reason}) do
    "cannot start stdio transport safely because runtime stdout isolation failed: " <>
      inspect(reason)
  end

  defp start_error({server, _server_opts}, reason),
    do: "cannot start stdio server #{inspect(server.name)}: #{inspect(reason)}"

  defp start_error(server_name, :not_running),
    do: "stdio server #{inspect(server_name)} is not running"

  defp decode_input(message) when is_map(message), do: {:ok, message}
  defp decode_input(line) when is_binary(line), do: JSONRPC.decode_json(line)

  defp decode_input(_message) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "stdio request must be a JSON-RPC object",
       details: %{jsonrpc_code: -32_600}
     }}
  end
end
