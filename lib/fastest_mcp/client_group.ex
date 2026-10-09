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
  alias FastestMCP.{Client, Deadline, Error, Options}
  alias FastestMCP.Client.{Catalog, Connection}
  alias FastestMCP.ClientGroup.Coordinator

  @default_timeout_ms 10_000

  defstruct [:coordinator, :supervisor]
  @opaque t :: %__MODULE__{coordinator: pid(), supervisor: pid()}

  @doc "Connects a group and returns an opaque operation and lifecycle handle."
  def connect(opts) do
    with {:ok, supervisor} <- start_link(opts) do
      Process.unlink(supervisor)
      handle(supervisor)
    end
  end

  @doc "Connects a group, raising on failure."
  def connect!(opts), do: Error.unwrap!(connect(opts))

  @doc "Starts a group and waits for every member to become ready."
  def start_link(opts) do
    configs = normalize_clients!(Keyword.fetch!(opts, :clients))
    concurrency = Keyword.get(opts, :max_concurrency, 8)
    Options.check!(concurrency, :pos_integer, :max_concurrency)
    opts = Keyword.merge(opts, clients: configs, max_concurrency: concurrency)
    deadline = Deadline.from_options(opts, @default_timeout_ms)

    with {:ok, timeout} <- Deadline.check(deadline, "client group"),
         {:ok, pid} <- Supervisor.start_link(__MODULE__, opts) do
      with {:ok, group} <- handle(pid),
           :ok <- await_ready(group, timeout) do
        {:ok, pid}
      else
        error ->
          Process.unlink(pid)
          if Process.alive?(pid), do: Supervisor.stop(pid)
          error
      end
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

  @doc "Returns the operation handle of a group started under `supervisor`."
  def handle(supervisor) do
    children = Supervisor.which_children(supervisor)

    case for({Coordinator, pid, _, _} when is_pid(pid) <- children, do: pid) do
      [pid] -> {:ok, %__MODULE__{coordinator: pid, supervisor: supervisor}}
      [] -> {:error, %Error{code: :not_found, message: "client group is not running"}}
    end
  catch
    :exit, reason -> {:error, Error.from_exit(reason)}
  end

  @doc "Raising variant of `handle/1`."
  def handle!(supervisor), do: Error.unwrap!(handle(supervisor))

  @doc "Stops a group and its owned clients; borrowed clients keep running."
  def disconnect(%__MODULE__{supervisor: supervisor}) do
    Supervisor.stop(supervisor)
  catch
    # Idempotent: a group that already stopped has stopped its clients.
    :exit, {reason, {GenServer, :stop, _args}} when reason in [:noproc, :normal, :shutdown] -> :ok
    :exit, reason -> {:error, Error.from_exit(reason)}
  end

  @doc "Raising variant of `disconnect/1`."
  def disconnect!(group), do: Error.unwrap!(disconnect(group))

  @doc "Returns whether all pinned member clients are ready."
  def ready?(group) do
    case members(group) do
      {:ok, members} -> Enum.all?(members, fn {_name, client} -> Client.ready?(client) end)
      {:error, _error} -> false
    end
  end

  @doc "Waits until every member client is ready, as `FastestMCP.Client.await_ready/2`."
  def await_ready(group, timeout \\ @default_timeout_ms) do
    deadline = Deadline.new(timeout)

    with {:ok, members} <- members(group) do
      Enum.find_value(members, :ok, fn {_name, client} ->
        with :ok <- Client.await_ready(client, Deadline.remaining(deadline)), do: nil
      end)
    end
  end

  @doc "Raising variant of `await_ready/2`."
  def await_ready!(group, timeout \\ @default_timeout_ms),
    do: Error.unwrap!(await_ready(group, timeout))

  @doc "Returns the pinned client of member `name`."
  def client(group, name) do
    with {:ok, members} <- members(group) do
      case Map.fetch(members, to_string(name)) do
        {:ok, client} ->
          Connection.pin(client)

        :error ->
          {:error,
           %Error{code: :not_found, message: "unknown client group member #{inspect(name)}"}}
      end
    end
  end

  @doc "Raising variant of `client/2`."
  def client!(group, name), do: Error.unwrap!(client(group, name))

  @doc "Returns the negotiated protocol version of every member."
  def protocol_versions(group) do
    with {:ok, members} <- members(group) do
      Enum.reduce_while(members, {:ok, %{}}, fn {name, client}, {:ok, versions} ->
        case Client.info(client) do
          {:ok, info} -> {:cont, {:ok, Map.put(versions, name, info.protocol_version)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Raising variant of `protocol_versions/1`."
  def protocol_versions!(group), do: Error.unwrap!(protocol_versions(group))

  @doc "Refreshes every member and returns the complete list of group tools."
  def list_tools(group, opts \\ []) do
    opts = deadline_options(opts)
    catalog_call(group, {:refresh, Keyword.put_new(opts, :cache, :refresh)}, opts[:deadline])
  end

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(group, opts \\ []), do: Error.unwrap!(list_tools(group, opts))

  @doc """
  Returns the route of a group tool. A route whose member catalog changed is
  revalidated against that member's fresh catalog.
  """
  def resolve_tool(group, name, opts \\ []) do
    opts = deadline_options(opts)
    name = to_string(name)

    with {:ok, route} <- catalog_call(group, {:route, name, opts}, opts[:deadline]),
         {:ok, revision} <- Catalog.revision(route.client) do
      cond do
        not revision.ready? ->
          {:error,
           %Error{
             code: :not_found,
             message: "client group member #{inspect(route.server_name)} is unavailable"
           }}

        revision.generation == route.generation and revision.fresh? ->
          {:ok, route}

        true ->
          revalidate(group, name, route, opts)
      end
    end
  end

  @doc "Raising variant of `resolve_tool/3`."
  def resolve_tool!(group, name, opts \\ []), do: Error.unwrap!(resolve_tool(group, name, opts))

  defp revalidate(group, name, route, opts) do
    with {:ok, snapshot} <- Catalog.snapshot(route.client, Keyword.put(opts, :cache, :use)) do
      if Enum.any?(snapshot.tools, &(&1["name"] == route.upstream_name)) do
        call(group, {:validated_route, name, route, %{route | generation: snapshot.generation}})
      else
        {:error,
         %Error{
           code: :method_not_found,
           message: "member no longer advertises tool #{inspect(name)}"
         }}
      end
    end
  end

  @doc "Calls a group tool on the member that advertises it."
  def call_tool(group, name, arguments \\ %{}, opts \\ []),
    do: routed(group, name, opts, &Client.call_tool(&1, &2, arguments, &3))

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(group, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(call_tool(group, name, arguments, opts))

  @doc "Starts a cancellable call of a group tool, owned by the calling process."
  def start_tool_result(group, name, arguments \\ %{}, opts \\ []),
    do: routed(group, name, opts, &Client.start_tool_result(&1, &2, arguments, &3))

  @doc "Raising variant of `start_tool_result/4`."
  def start_tool_result!(group, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(start_tool_result(group, name, arguments, opts))

  # The group's deadline also bounds the member call.
  defp routed(group, name, opts, fun) do
    opts = deadline_options(opts)

    with {:ok, route} <- resolve_tool(group, name, opts),
         do: fun.(route.client, route.upstream_name, opts)
  end

  defp deadline_options(opts),
    do: Keyword.put(opts, :deadline, Deadline.from_options(opts, @default_timeout_ms))

  defp members(group), do: call(group, :members)

  defp catalog_call(group, request, deadline) do
    with {:ok, timeout} <- Deadline.check(deadline, "client group"),
         do: call(group, request, Connection.call_timeout(timeout))
  end

  defp call(group, request, timeout \\ 5_000) do
    coordinator =
      case group do
        %__MODULE__{coordinator: pid} -> pid
        reference -> reference
      end

    GenServer.call(coordinator, request, timeout)
  catch
    :exit, reason -> {:error, Error.from_exit(reason)}
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

            # Members start inside the group's supervisor; reject bad options here.
            Client.child_spec(opts)

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
