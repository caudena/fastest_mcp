defmodule FastestMCP.Client.Options do
  @moduledoc false
  # Client option validation, run in the caller before any process starts.
  # `validate!/2` turns a target and its connection options into a
  # `%FastestMCP.Client.Config{}`; `operation!/1` checks the options of one
  # operation. Invalid options raise `ArgumentError` without printing values
  # that may be credentials.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.Config
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.ResponseCache
  alias FastestMCP.Client.Transport
  alias FastestMCP.Options
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Root
  alias FastestMCP.Sampling
  alias FastestMCP.SamplingTool

  @connection [
    name: {:any, nil},
    protocol_version: {:any, :auto},
    auto_initialize: {:boolean, true},
    session_stream: {:boolean, false},
    init_timeout_ms: {:limit, 10_000},
    timeout_ms: {:pos_integer, 5_000},
    max_in_flight: {:limit, nil},
    max_mrtr_rounds: {:pos_integer, 8},
    max_response_bytes: {:pos_integer, 16 * 1_024 * 1_024},
    max_sse_event_bytes: {:pos_integer, 1_024 * 1_024},
    max_callback_request_ids: {:pos_integer, 100_000},
    sse_reconnect: {:any, true},
    stdio_restart: {:any, true},
    response_cache: {:any, false},
    roots: {:any, nil},
    extensions: {:any, nil},
    schema_options: {:keyword, []},
    client_info: {:any, nil},
    sampling_tools: {:any, nil},
    sampling_context: {:any, nil},
    sampling_handler: {:function, nil},
    elicitation_handler: {:function, nil},
    url_elicitation_handler: {:function, nil},
    elicitation_complete_handler: {:function, nil},
    log_handler: {:function, nil},
    progress_handler: {:function, nil},
    notification_handler: {:function, nil},
    auth_input: {:any, nil},
    authorization: {:any, nil},
    access_token: {:any, nil},
    headers: {:any, nil},
    oauth: {:any, nil},
    legacy_stdio_auth_metadata: {:boolean, false},
    env: {:any, nil},
    stdio_process_group: {:any, nil}
  ]

  # The in-process transport has no HTTP, SSE, or child process.
  @not_in_process ~w(oauth headers authorization access_token session_stream sse_reconnect
                     max_sse_event_bytes env legacy_stdio_auth_metadata stdio_restart
                     stdio_process_group)a

  @removed %{
    session_id: "client session_id is server-negotiated and cannot be configured",
    supported_protocol_versions:
      "supported_protocol_versions is not configurable; use protocol_version: :auto or an exact supported version"
  }

  @sse_reconnect [max_attempts: 3, min_retry_ms: 0, max_retry_ms: 30_000, default_retry_ms: 1_000]
  @stdio_restart [max_attempts: 3, retry_ms: 1_000, max_retry_ms: 30_000]

  # Every option an operation reads. `deadline` is an absolute monotonic
  # deadline shared by the operations of a client group;
  # `http_parameter_headers` are the Mcp-Param headers of a raw request.
  @operation ~w(timeout_ms deadline task_timeout_ms cache cursor max_pages max_items
                max_mrtr_rounds meta progress_token progress_handler on_notification auth_input
                authorization access_token headers http_parameter_headers task version
                context_arguments status statuses kind target output_validator total message)a

  @handlers ~w(sampling_handler elicitation_handler url_elicitation_handler
               elicitation_complete_handler log_handler progress_handler notification_handler)a

  @auth ~w(auth_input authorization access_token headers)a

  @invalid_env "stdio env must be a map or keyword list of scalar values"

  @spec validate!(term(), keyword()) :: Config.t()
  def validate!(target, opts) do
    if Keyword.keyword?(opts) do
      for {key, _value} <- opts, hint = @removed[key], do: raise(ArgumentError, hint)
    end

    options = Options.validate!(opts, @connection)
    transport = transport!(target, options)
    supported!(opts, transport.type)
    auth!(opts)
    protocol_version = protocol_version!(options.protocol_version)
    {max_auth_attempts, oauth} = oauth!(options.oauth)

    # Validated options seed the config; normalized values replace raw ones.
    struct(
      Config,
      Map.merge(options, %{
        transport: transport,
        protocol_version: protocol_version,
        max_in_flight: max_in_flight!(options.max_in_flight, transport.type, protocol_version),
        sse_reconnect:
          retry_policy!(options.sse_reconnect, :sse_reconnect, @sse_reconnect, :min_retry_ms),
        stdio_restart:
          retry_policy!(options.stdio_restart, :stdio_restart, @stdio_restart, :retry_ms),
        response_cache: ResponseCache.new(options.response_cache),
        roots: roots!(options.roots),
        extensions: Extensions.declare_oauth_grant(options.extensions, options.oauth),
        client_info: client_info!(options.client_info),
        sampling_tools: sampling_tools!(options.sampling_tools),
        auth_input: Auth.normalize(opts),
        oauth: oauth,
        max_auth_attempts: max_auth_attempts
      })
    )
  end

  @spec operation!(keyword()) :: keyword()
  def operation!(opts) do
    opts = opts |> Options.keys!(@operation) |> auth!()

    for {key, rule} <- [
          timeout_ms: :limit,
          task_timeout_ms: :limit,
          max_mrtr_rounds: :pos_integer
        ],
        Keyword.has_key?(opts, key),
        do: Options.check!(opts[key], rule, key)

    Keyword.replace_lazy(opts, :meta, &wire_map/1)
  end

  # A user map the client reads like a wire map (raw params, a task status,
  # `meta:`) takes string keys, at its top level and in its `_meta`.
  @spec wire_map(map() | keyword()) :: map()
  def wire_map(map) do
    map = Map.new(map, fn {key, value} -> {to_string(key), value} end)
    with %{"_meta" => %{} = meta} <- map, do: %{map | "_meta" => wire_map(meta)}
  end

  # A handler replaced at runtime is one of the connection's handler options.
  @spec handler!(atom(), function() | nil) :: :ok
  def handler!(key, handler) do
    unless key in @handlers do
      raise ArgumentError,
            "unknown handler #{inspect(key)}, the handlers are: #{inspect(@handlers)}"
    end

    if handler, do: Options.check!(handler, :function, key)
    :ok
  end

  # Replacement credentials take the auth options of a connection.
  @spec auth_input!(keyword()) :: map()
  def auth_input!(opts), do: opts |> Options.keys!(@auth) |> auth!() |> Auth.normalize()

  @spec roots(term()) :: {:ok, [Root.t()] | nil} | {:error, FastestMCP.Error.t()}
  def roots(nil), do: {:ok, nil}

  def roots(roots) when is_list(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case Root.parse(root) do
        {:ok, root} ->
          {:cont, {:ok, [root | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            %FastestMCP.Error{
              code: :invalid_params,
              message: "invalid client root",
              details: %{reason: inspect(reason)}
            }}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, roots |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def roots(_roots),
    do: {:error, %FastestMCP.Error{code: :invalid_params, message: "client roots must be a list"}}

  defp transport!({:stdio, command}, options), do: transport!({:stdio, command, []}, options)

  defp transport!({:stdio, command, args}, options) when is_binary(command) and is_list(args) do
    %{
      type: :stdio,
      adapter: Transport.Stdio,
      command: command,
      args: Enum.map(args, &to_string/1),
      env: env!(options.env),
      process_group: process_group!(options.stdio_process_group),
      stdio_process: nil,
      generation: 0,
      port: nil,
      session_id: nil
    }
  end

  defp transport!({:in_process, server_name}, _options)
       when is_binary(server_name) or is_atom(server_name) do
    %{
      type: :in_process,
      adapter: Transport.InProcess,
      server_name: to_string(server_name),
      session_id: nil,
      coordinator: nil,
      supervisor: nil
    }
  end

  defp transport!(url, _options) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} = uri when scheme in ["http", "https"] ->
        %{
          type: :streamable_http,
          adapter: Transport.StreamableHTTP,
          base_url: uri |> default_path() |> URI.to_string(),
          session_id: nil
        }

      _other ->
        raise ArgumentError, "unsupported client target: #{inspect(url)}"
    end
  end

  defp transport!(target, _options),
    do: raise(ArgumentError, "unsupported client target: #{inspect(target)}")

  defp default_path(%URI{path: path} = uri) when path in [nil, "", "/"], do: %{uri | path: "/mcp"}
  defp default_path(uri), do: uri

  defp supported!(opts, type) do
    unsupported =
      case type do
        :in_process -> @not_in_process
        :stdio -> [:oauth]
        :streamable_http -> []
      end

    case for({key, _value} <- opts, key in unsupported, do: key) do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "the #{transport_name(type)} client transport does not accept #{inspect(keys)}"
    end
  end

  defp auth!(opts) do
    for key <- [:authorization, :access_token],
        value = opts[key],
        not is_binary(value),
        do: raise(ArgumentError, "#{key} must be a string")

    for key <- [:auth_input, :headers],
        value = opts[key],
        not pairs?(value),
        do: raise(ArgumentError, "#{key} must be a map or a list of pairs")

    opts
  end

  defp pairs?(value),
    do: is_map(value) or (is_list(value) and Enum.all?(value, &match?({_, _}, &1)))

  defp protocol_version!(version) do
    if version == :auto or version in Protocol.supported_versions() do
      version
    else
      raise ArgumentError,
            "protocol_version must be :auto or one of #{inspect(Protocol.supported_versions())}, got: #{inspect(version)}"
    end
  end

  # Legacy stdio and in-process connections carry one request at a time.
  defp max_in_flight!(nil, type, legacy()) when type != :streamable_http, do: 1
  defp max_in_flight!(nil, _type, _version), do: 10

  defp max_in_flight!(max, type, legacy()) when type != :streamable_http and max != 1 do
    raise ArgumentError,
          "legacy #{transport_name(type)} max_in_flight must be 1, got: #{inspect(max)}"
  end

  defp max_in_flight!(max, _type, _version), do: max

  # Bounded retries of SSE reconnects and stdio restarts: `true` selects the
  # defaults, `false` disables them, and `floor` may not exceed max_retry_ms.
  defp retry_policy!(false, _key, defaults, _floor),
    do: Map.new(defaults, fn {name, _default} -> {name, 0} end)

  defp retry_policy!(true, key, defaults, floor), do: retry_policy!([], key, defaults, floor)

  defp retry_policy!(opts, key, defaults, floor) when is_list(opts) do
    spec = Enum.map(defaults, fn {name, default} -> {name, {:non_neg_integer, default}} end)
    policy = Options.validate!(opts, spec)

    if policy[floor] > policy.max_retry_ms or policy.max_retry_ms > 60_000 do
      raise ArgumentError,
            "invalid #{key} retry bounds: #{floor} must not exceed max_retry_ms, which must not exceed 60000"
    end

    policy
  end

  defp retry_policy!(other, key, _defaults, _floor) do
    raise ArgumentError, "#{key} must be a keyword list, true, or false, got: #{inspect(other)}"
  end

  defp oauth!(nil), do: {nil, nil}

  defp oauth!(oauth) do
    unless Keyword.keyword?(oauth), do: raise(ArgumentError, "oauth must be a keyword list")
    {attempts, oauth} = Keyword.pop(oauth, :max_auth_attempts, 3)

    case OAuth.Config.new(oauth) do
      {:ok, config} -> {Options.check!(attempts, :non_neg_integer, :max_auth_attempts), config}
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defp roots!(roots) do
    case roots(roots) do
      {:ok, roots} ->
        roots

      {:error, error} ->
        raise ArgumentError, Enum.join([error.message | Map.values(error.details)], ": ")
    end
  end

  defp client_info!(nil), do: %{"name" => "FastestMCP.Client", "version" => version()}
  defp client_info!(%{} = info), do: Map.new(info, fn {key, value} -> {to_string(key), value} end)

  defp client_info!(other),
    do: raise(ArgumentError, "client_info must be a map, got: #{inspect(other)}")

  defp version do
    case Application.spec(:fastest_mcp, :vsn) do
      nil -> "0.2.0"
      version -> to_string(version)
    end
  end

  defp sampling_tools!(nil), do: []

  defp sampling_tools!(tools) when is_list(tools) do
    tools
    |> Sampling.prepare_tools()
    |> List.wrap()
    |> Enum.map(fn
      %SamplingTool{name: name, runner: runner} = tool
      when is_binary(name) and name != "" and is_function(runner, 1) ->
        SamplingTool.new(name, runner, description: tool.description, parameters: tool.parameters)

      tool ->
        raise ArgumentError,
              "sampling_tools must contain executable FastestMCP.SamplingTool values, got: #{inspect(tool)}"
    end)
  end

  defp sampling_tools!(other),
    do: raise(ArgumentError, "sampling_tools must be a list, got: #{inspect(other)}")

  defp env!(nil), do: :inherit
  defp env!(env) when is_map(env), do: env |> Map.to_list() |> env!()

  defp env!(env) when is_list(env) do
    entries = Enum.map(env, &env_entry!/1)
    names = Enum.map(entries, &elem(&1, 0))

    bytes =
      Enum.reduce(entries, 0, fn {name, value}, sum -> sum + byte_size(name <> value) + 2 end)

    cond do
      length(names) != length(Enum.uniq(names)) ->
        raise ArgumentError, "stdio env contains duplicate variable names"

      length(entries) > 512 or bytes > 65_536 or
          Enum.any?(entries, fn {_name, value} -> byte_size(value) > 16_384 end) ->
        raise ArgumentError, "stdio env exceeds the bounded environment size"

      true ->
        {:replace, Enum.sort(entries)}
    end
  end

  defp env!(_env), do: raise(ArgumentError, @invalid_env)

  defp env_entry!({name, value})
       when (is_binary(name) or is_atom(name)) and
              (is_binary(value) or is_integer(value) or
                 (is_atom(value) and value not in [false, nil])) do
    {name, value} = {to_string(name), to_string(value)}

    if byte_size(name) in 1..128 and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and
         not String.contains?(value, <<0>>) do
      {name, value}
    else
      raise ArgumentError, @invalid_env
    end
  end

  defp env_entry!(_entry), do: raise(ArgumentError, @invalid_env)

  defp process_group!(nil), do: nil

  defp process_group!(opts) do
    with true <-
           Keyword.keyword?(opts) and Keyword.keys(opts) -- [:launcher, :launcher_args] == [],
         launcher when is_binary(launcher) <- opts[:launcher],
         true <- Path.type(launcher) == :absolute and not String.contains?(launcher, <<0>>),
         args when is_list(args) and length(args) <= 64 <- Keyword.get(opts, :launcher_args, []),
         args = Enum.map(args, &launcher_arg/1),
         true <- :error not in args and byte_size(Enum.join([launcher | args])) <= 16_384 do
      %{launcher: launcher, launcher_args: args}
    else
      _invalid ->
        raise ArgumentError,
              "stdio_process_group must be a keyword list with an absolute :launcher and bounded :launcher_args"
    end
  end

  defp launcher_arg(arg) when is_binary(arg) or is_atom(arg) or is_integer(arg) do
    arg = to_string(arg)
    if byte_size(arg) <= 4_096 and not String.contains?(arg, <<0>>), do: arg, else: :error
  end

  defp launcher_arg(_arg), do: :error

  defp transport_name(:stdio), do: "stdio"
  defp transport_name(:in_process), do: "in-process"
end
