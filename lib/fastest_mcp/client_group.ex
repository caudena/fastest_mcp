defmodule FastestMCP.ClientGroup do
  @moduledoc """
  Supervised coordination of independent MCP clients.

  Each entry in `clients:` is a keyword configuration accepted by
  `FastestMCP.Client.start_link/1`, or `{:existing, client_ref}` to borrow a
  client. Only configured clients belong to this supervisor. Members negotiate
  independently; tools are exposed as `<alias>_<upstream_name>`.

      {FastestMCP.ClientGroup,
       name: MyApp.MCP,
       clients: %{
         "reports" => [target: "https://reports.example/mcp"],
         "local" => {:existing, MyApp.LocalClient}
       }}

  `list_tools/2` refreshes every member and atomically replaces the routing
  catalog. Failed refreshes do not publish partial lists. Known routes to
  healthy members remain callable. An explicit refresh rebinds named borrowed
  clients; in-flight calls never move to replacement processes.

  Stop a supervised group through its owning Supervisor. Borrowed clients are
  never stopped. Prompts and resources remain accessible through `client/2`.
  """
  use Supervisor
  alias FastestMCP.{Client, Error}
  alias FastestMCP.ClientGroup.Coordinator

  defstruct [:coordinator, :supervisor]
  @opaque t :: %__MODULE__{coordinator: pid(), supervisor: pid()}

  @doc "Connects a group and returns an opaque operation and lifecycle handle."
  def connect(opts) do
    case start_link(opts) do
      {:ok, supervisor} ->
        Process.unlink(supervisor)
        {:ok, execute_handle(supervisor)}

      error ->
        error
    end
  end

  @doc "Connects a group, raising on failure."
  def connect!(opts), do: FastestMCP.OperationResult.unwrap!(connect(opts))

  defp execute_handle(supervisor) do
    coordinator =
      Supervisor.which_children(supervisor)
      |> Enum.find_value(fn
        {Coordinator, pid, _, _} when is_pid(pid) -> pid
        _ -> nil
      end)

    if coordinator do
      %__MODULE__{coordinator: coordinator, supervisor: supervisor}
    else
      raise Error, code: :not_found, message: "client group is not running"
    end
  end

  defp execute_disconnect(%__MODULE__{supervisor: supervisor}), do: Supervisor.stop(supervisor)

  @doc "Starts a group and waits for every member to become ready."
  def start_link(opts) do
    configs = normalize_clients!(Keyword.fetch!(opts, :clients))
    opts = deadline_options(opts)
    timeout = FastestMCP.Deadline.remaining!(opts[:deadline], "client group")
    concurrency = positive!(Keyword.get(opts, :max_concurrency, 8), :max_concurrency)
    opts = opts |> Keyword.put(:clients, configs) |> Keyword.put(:max_concurrency, concurrency)

    case Supervisor.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        try do
          :ok = execute_await_ready(execute_handle(pid), timeout)
          {:ok, pid}
        rescue
          error ->
            stop_failed_start(pid)
            {:error, error}
        catch
          kind, reason ->
            stop_failed_start(pid)
            {:error, {kind, reason}}
        end

      error ->
        error
    end
  end

  @doc "Returns a supervisor child specification for this group."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: Keyword.get(opts, :restart, :permanent),
      shutdown: :infinity
    }
  end

  @impl true
  def init(opts) do
    children = [
      {Task.Supervisor, []},
      {__MODULE__.Members, opts[:clients]},
      {Coordinator, {self(), opts}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Returns whether all pinned member clients are ready."
  def ready?(group) do
    group |> members() |> Enum.all?(fn {_, client} -> Client.ready?(client) end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp execute_await_ready(group, timeout) do
    deadline = FastestMCP.Deadline.new(positive!(timeout, :timeout_ms))

    Enum.each(members(group), fn {_, client} ->
      remaining = FastestMCP.Deadline.remaining!(deadline, "client group readiness")

      :ok = Client.await_ready!(client, remaining)
    end)

    :ok
  end

  defp execute_client(group, name) do
    case Map.fetch(members(group), to_string(name)) do
      {:ok, client} ->
        Client.pin!(client)

      :error ->
        raise Error, code: :not_found, message: "unknown client group member #{inspect(name)}"
    end
  end

  defp execute_protocol_versions(group),
    do: Map.new(members(group), fn {name, client} -> {name, Client.protocol_version!(client)} end)

  defp execute_list_tools(group, opts) do
    opts = deadline_options(opts)
    timeout = FastestMCP.Deadline.remaining!(opts[:deadline], "client group")
    call(group, {:refresh, Keyword.put_new(opts, :cache, :refresh)}, timeout + 1_000)
  end

  defp execute_resolve_tool(group, name, opts) do
    opts = deadline_options(opts)
    timeout = FastestMCP.Deadline.remaining!(opts[:deadline], "client group")
    route = call(group, {:route, to_string(name), opts}, timeout + 1_000)
    revision = Client.catalog_revision!(route.client)

    unless revision.ready?,
      do:
        raise(Error,
          code: :not_found,
          message: "client group member #{inspect(route.server_name)} is unavailable"
        )

    if revision.generation != route.generation or not revision.fresh? do
      snapshot = Client.catalog_snapshot!(route.client, Keyword.put(opts, :cache, :use))

      unless Enum.any?(snapshot.tools, &(&1["name"] == route.upstream_name)) do
        raise Error,
          code: :method_not_found,
          message: "member no longer advertises tool #{inspect(name)}"
      end

      updated = %{route | generation: snapshot.generation}
      call(group, {:validated_route, to_string(name), route, updated})
    else
      route
    end
  end

  defp execute_call_tool(group, name, arguments, opts) do
    opts = deadline_options(opts)
    route = execute_resolve_tool(group, name, opts)
    Client.call_tool!(route.client, route.upstream_name, arguments, opts)
  end

  defp execute_start_tool_result(group, name, arguments, opts) do
    opts = deadline_options(opts)
    route = execute_resolve_tool(group, name, opts)
    Client.start_tool_result!(route.client, route.upstream_name, arguments, opts)
  end

  defp deadline_options(opts) do
    Keyword.put(opts, :deadline, FastestMCP.Deadline.from_options(opts, 10_000))
  end

  defp members(group), do: call(group, :members)

  defp call(group, request, timeout \\ 5_000) do
    coordinator =
      case group do
        %__MODULE__{coordinator: pid} -> pid
        reference -> reference
      end

    case GenServer.call(coordinator, request, timeout) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  catch
    :exit, reason -> raise FastestMCP.OperationResult.exit_error(reason)
  end

  defp stop_failed_start(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: Supervisor.stop(pid)
  end

  defp normalize_clients!(clients) when is_map(clients) and map_size(clients) > 0 do
    normalized =
      Enum.map(clients, fn {alias_name, config} ->
        name = to_string(alias_name)
        if String.trim(name) == "", do: raise(ArgumentError, "client aliases must not be empty")

        case config do
          {:existing, _ref} ->
            :ok

          opts when is_list(opts) ->
            unless Keyword.keyword?(opts) and Keyword.has_key?(opts, :target),
              do: raise(ArgumentError, "owned clients require keyword options with :target")

          _ ->
            raise ArgumentError, "clients must be configurations or {:existing, client_ref}"
        end

        {name, config}
      end)

    if length(normalized) != map_size(Map.new(normalized)),
      do: raise(ArgumentError, "client aliases collide after normalization")

    Enum.sort(normalized)
  end

  defp normalize_clients!(_), do: raise(ArgumentError, "clients must be a non-empty map")
  defp positive!(value, _) when is_integer(value) and value > 0, do: value
  defp positive!(_, key), do: raise(ArgumentError, "#{key} must be a positive integer")
  @doc "Runs `await_ready` and returns a tagged result."
  def await_ready(group, timeout \\ 10_000),
    do:
      FastestMCP.OperationResult.capture(fn -> execute_await_ready(group, timeout) end, :command)

  @doc "Raising variant of `await_ready/2`."
  def await_ready!(group, timeout \\ 10_000),
    do: FastestMCP.OperationResult.unwrap!(await_ready(group, timeout))

  @doc "Runs `call_tool` and returns a tagged result."
  def call_tool(group, name, arguments \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_call_tool(group, name, arguments, opts) end,
        :value
      )

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(group, name, arguments \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(call_tool(group, name, arguments, opts))

  @doc "Runs `client` and returns a tagged result."
  def client(group, name),
    do: FastestMCP.OperationResult.capture(fn -> execute_client(group, name) end, :value)

  @doc "Raising variant of `client/2`."
  def client!(group, name), do: FastestMCP.OperationResult.unwrap!(client(group, name))

  @doc "Runs `disconnect` and returns a tagged result."
  def disconnect(group),
    do: FastestMCP.OperationResult.capture(fn -> execute_disconnect(group) end, :command)

  @doc "Raising variant of `disconnect/1`."
  def disconnect!(group),
    do: FastestMCP.OperationResult.unwrap!(disconnect(group))

  @doc "Runs `handle` and returns a tagged result."
  def handle(supervisor),
    do: FastestMCP.OperationResult.capture(fn -> execute_handle(supervisor) end, :value)

  @doc "Raising variant of `handle/1`."
  def handle!(supervisor), do: FastestMCP.OperationResult.unwrap!(handle(supervisor))

  @doc "Runs `list_tools` and returns a tagged result."
  def list_tools(group, opts \\ []),
    do: FastestMCP.OperationResult.capture(fn -> execute_list_tools(group, opts) end, :value)

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(group, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(list_tools(group, opts))

  @doc "Runs `protocol_versions` and returns a tagged result."
  def protocol_versions(group),
    do: FastestMCP.OperationResult.capture(fn -> execute_protocol_versions(group) end, :value)

  @doc "Raising variant of `protocol_versions/1`."
  def protocol_versions!(group), do: FastestMCP.OperationResult.unwrap!(protocol_versions(group))

  @doc "Runs `resolve_tool` and returns a tagged result."
  def resolve_tool(group, name, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_resolve_tool(group, name, opts) end,
        :value
      )

  @doc "Raising variant of `resolve_tool/3`."
  def resolve_tool!(group, name, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(resolve_tool(group, name, opts))

  @doc "Runs `start_tool_result` and returns a tagged result."
  def start_tool_result(group, name, arguments \\ %{}, opts \\ []),
    do:
      FastestMCP.OperationResult.capture(
        fn -> execute_start_tool_result(group, name, arguments, opts) end,
        :value
      )

  @doc "Raising variant of `start_tool_result/4`."
  def start_tool_result!(group, name, arguments \\ %{}, opts \\ []),
    do: FastestMCP.OperationResult.unwrap!(start_tool_result(group, name, arguments, opts))

  @deprecated "Use call_tool/4."
  def call_tool_result(group, name, arguments \\ %{}, opts \\ []),
    do: call_tool(group, name, arguments, opts)
end

defmodule FastestMCP.ClientGroup.Members do
  @moduledoc false
  use Supervisor
  def start_link(configs), do: Supervisor.start_link(__MODULE__, configs)
  @impl true
  def init(configs) do
    children =
      Enum.flat_map(configs, fn
        {_, {:existing, _}} -> []
        {name, opts} -> [FastestMCP.Client.child_spec(Keyword.put(opts, :id, {:client, name}))]
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
