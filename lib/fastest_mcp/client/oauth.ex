defmodule FastestMCP.Client.OAuth do
  @moduledoc """
  MCP OAuth coordinator for HTTP clients.

  The coordinator implements protected-resource and authorization-server
  discovery, RFC 9207 issuer validation, PKCE S256, resource indicators,
  explicit client registration modes, refresh-token rotation, scope step-up,
  and the official client-credentials and enterprise-managed grant profiles.
  Browser interaction remains behind
  `FastestMCP.Client.OAuth.AuthorizationHandler`.

  Start one coordinator per connected client. The default token store is
  process-local and non-durable:

      {:ok, oauth} =
        FastestMCP.Client.OAuth.start_link(
          redirect_uri: "http://127.0.0.1:8765/callback",
          registration: {:pre_registered, [client_id: "my-client"]},
          authorization_handler: MyApp.OAuthBrowser
        )

  The connected client normally invokes this module automatically after a 401
  response. Direct calls are useful to hosts that want to authorize eagerly.

  Discovery, registration, token requests, and the host callbacks run in a
  task per resource, never in the coordinator. Concurrent calls for a resource
  share its running flow (the authorization handler runs once), while other
  resources and current tokens answer at once. A caller that times out stops
  waiting; the flow still completes and stores its token. `clear/2` cancels
  the resource's flow.
  """

  use GenServer

  alias FastestMCP.Client.OAuth.AuthorizationHandler
  alias FastestMCP.Client.OAuth.ClientAssertionProvider
  alias FastestMCP.Client.OAuth.Config
  alias FastestMCP.Client.OAuth.EnterpriseManagedProvider
  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Client.OAuth.Flow
  alias FastestMCP.Client.OAuth.TokenStore.Memory
  alias FastestMCP.Client.OAuth.URL

  @refresh_skew_ms 30_000

  @type registration ::
          {:pre_registered, keyword() | map()}
          | {:client_metadata_document, String.t()}
          | {:dynamic, keyword() | map()}

  @type assertion_provider ::
          module() | (ClientAssertionProvider.Request.t() -> ClientAssertionProvider.response())

  @type enterprise_provider ::
          module()
          | (EnterpriseManagedProvider.Request.t() -> EnterpriseManagedProvider.response())

  @type grant ::
          :authorization_code
          | {:authorization_code, keyword() | map()}
          | {:client_credentials, keyword() | map()}
          | {:enterprise_managed, keyword() | map()}

  @type option ::
          {:redirect_uri, String.t()}
          | {:grant, grant()}
          | {:registration, registration()}
          | {:authorization_handler, module() | (AuthorizationHandler.Request.t() -> term())}
          | {:token_store, {module(), term()}}
          | {:authorization_server, String.t()}
          | {:scopes, [String.t()]}
          | {:application_type, String.t()}
          | {:requester, (atom(), String.t(), keyword() -> term())}
          | {:timeout_ms, pos_integer()}
          | {:max_body_bytes, pos_integer()}

  @doc """
  Starts an OAuth coordinator from explicit client options.

  Invalid option values return a `:configuration` error; unknown options
  raise `ArgumentError`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- Config.new(opts), do: GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Returns a cached or refreshed Bearer header, or `:none` before authorization.

  A current token answers at once; otherwise the caller waits up to `timeout`
  milliseconds for the resource's refresh or running flow.
  """
  @spec authorization_header(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | :none | {:error, Error.t()}
  def authorization_header(server, resource, timeout \\ 5_000) when is_binary(resource) do
    with {:ok, resource} <- resource(resource, :configuration),
         do: call(server, {:header, resource}, timeout)
  end

  @doc """
  Handles a protected-resource challenge and returns a Bearer header.

  `attempt: 1` (the default) refreshes a stored token before authorizing,
  unless the challenge asks for more scope. `timeout_ms:` bounds the wait
  (default `:infinity`).
  """
  @spec handle_unauthorized(GenServer.server(), String.t(), list() | map(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def handle_unauthorized(server, resource, response_headers, opts \\ [])
      when is_binary(resource) and is_list(opts) do
    with {:ok, resource} <- resource(resource, :protected_resource_discovery) do
      challenge = Flow.challenge(response_headers)
      refresh? = Keyword.get(opts, :attempt, 1) == 1 and challenge.error != "insufficient_scope"
      request = {:authorize, resource, challenge, opts[:scopes], refresh?}
      call(server, request, Keyword.get(opts, :timeout_ms, :infinity))
    end
  end

  @doc """
  Performs authorization without requiring a preceding 401 response.

  Takes `scopes:`, `resource_metadata:`, and `timeout_ms:` (default `:infinity`).
  """
  @spec authorize(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def authorize(server, resource, opts \\ []) when is_binary(resource) and is_list(opts) do
    with {:ok, resource} <- resource(resource, :configuration) do
      challenge = %{
        resource_metadata: opts[:resource_metadata],
        scopes: opts[:scopes],
        error: nil
      }

      request = {:authorize, resource, challenge, opts[:scopes], false}
      call(server, request, Keyword.get(opts, :timeout_ms, :infinity))
    end
  end

  @doc "Deletes cached credentials for one resource and cancels its running flow."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(server, resource) when is_binary(resource) do
    case URL.resource(resource) do
      {:ok, resource} -> GenServer.call(server, {:clear, resource})
      {:error, _reason} -> :ok
    end
  end

  defp resource(resource, stage) do
    with {:error, reason} <- URL.resource(resource), do: error(stage, reason)
  end

  defp call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:timeout, _call} -> error(:authorization, :timeout)
    :exit, _reason -> error(:authorization, :unavailable)
  end

  ## Coordinator

  # `flights` holds the running flow of each resource: its task, the callers
  # waiting for its token, and authorization requests queued behind a refresh.

  @impl true
  def init(%Config{} = config) do
    with {:ok, tasks} <- Task.Supervisor.start_link(),
         {:ok, store} <- open_store(config.token_store) do
      {:ok,
       %{
         config: config,
         store: store,
         tasks: tasks,
         resources: %{},
         registrations: %{},
         bindings: %{},
         flights: %{}
       }}
    end
  end

  defp open_store(nil), do: with({:ok, pid} <- Memory.start_link(), do: {:ok, {Memory, pid}})
  defp open_store(store), do: {:ok, store}

  # The flow tasks stop with their linked supervisor; the default store does
  # not follow a normal exit.
  @impl true
  def terminate(_reason, %{config: %{token_store: nil}, store: {Memory, pid}}),
    do: FastestMCP.Util.stop_process(pid)

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:header, resource}, from, state) do
    context = state.resources[resource]
    token = context && read(state, context)

    cond do
      current?(token) ->
        {:reply, {:ok, bearer(token)}, state}

      Map.has_key?(state.flights, resource) ->
        {:noreply, join(state, resource, from)}

      is_nil(token) ->
        {:reply, :none, state}

      is_binary(token["refresh_token"]) ->
        {:noreply, fly(state, resource, from, refresh: :only)}

      # Grants without a user reacquire an expired token.
      context.grant != :authorization_code ->
        challenge = %{resource_metadata: nil, scopes: token["scope"], error: nil}
        fields = [token: nil, drop?: true, challenge: challenge, extra_scopes: token["scope"]]
        {:noreply, fly(state, resource, from, fields)}

      true ->
        delete(state, context.token_key)
        {:reply, :none, notify(state, resource, token["access_token"])}
    end
  end

  def handle_call({:authorize, resource, challenge, scopes, refresh?} = request, from, state) do
    case state.flights[resource] do
      nil ->
        refresh = if refresh?, do: :first, else: :never
        fields = [challenge: challenge, extra_scopes: scopes, refresh: refresh]
        {:noreply, fly(state, resource, from, fields)}

      # A refresh alone does not answer an authorization: it runs after.
      %{refresh: :only} ->
        {:noreply, update_in(state.flights[resource].queue, &[{request, from} | &1])}

      _flight ->
        {:noreply, join(state, resource, from)}
    end
  end

  def handle_call({:clear, resource}, _from, state) do
    before = credential(state, resource)
    {context, resources} = Map.pop(state.resources, resource)
    if context, do: delete(state, context.token_key)
    state = cancel(%{state | resources: resources}, resource)
    {:reply, :ok, notify(state, resource, before)}
  end

  def handle_call({:bind, client_id, issuer}, _from, state) do
    case Map.get(state.bindings, client_id, issuer) do
      ^issuer -> {:reply, :ok, put_in(state.bindings[client_id], issuer)}
      _other -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, land(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, land(state, ref, :crashed)}

  def handle_info(_message, state), do: {:noreply, state}

  defp fly(state, resource, from, fields) do
    context = state.resources[resource]

    flow = %Flow{
      config: state.config,
      coordinator: self(),
      resource: resource,
      context: context,
      token: context && read(state, context),
      registrations: state.registrations
    }

    flow = struct!(flow, fields)
    task = Task.Supervisor.async_nolink(state.tasks, Flow, :run, [flow])
    flight = %{task: task, refresh: flow.refresh, waiters: [from], queue: []}
    put_in(state.flights[resource], flight)
  end

  defp join(state, resource, from),
    do: update_in(state.flights[resource].waiters, &[from | &1])

  defp cancel(state, resource) do
    case Map.pop(state.flights, resource) do
      {nil, _flights} ->
        state

      {flight, flights} ->
        Task.shutdown(flight.task, :brutal_kill)
        reply(flight, error(:authorization, :cleared))
        %{state | flights: flights}
    end
  end

  # Applies a finished flow, answers its callers, then dispatches the
  # authorization requests that waited for its refresh.
  defp land(state, ref, outcome) do
    case Enum.find(state.flights, fn {_resource, flight} -> flight.task.ref == ref end) do
      nil ->
        state

      {resource, flight} ->
        {reply, state} =
          settle(%{state | flights: Map.delete(state.flights, resource)}, resource, outcome)

        Enum.each(flight.waiters, &GenServer.reply(&1, reply))

        flight.queue
        |> Enum.reverse()
        |> Enum.reduce(state, fn {request, from}, state ->
          {:noreply, state} = handle_call(request, from, state)
          state
        end)
    end
  end

  defp settle(state, _resource, :crashed), do: {error(:authorization, :flow_crashed), state}

  # Registrations are only ever added, so merging a snapshot loses none.
  defp settle(state, resource, {result, %Flow{} = flow}) do
    before = credential(state, resource)
    old = state.resources[resource]
    state = %{state | registrations: Map.merge(state.registrations, flow.registrations)}

    case result do
      {:ok, token} ->
        if old && old.token_key != flow.context.token_key, do: delete(state, old.token_key)
        write(state, flow.context.token_key, token)
        state = put_in(state.resources[resource], flow.context)
        {{:ok, bearer(token)}, notify(state, resource, before)}

      {:error, _error} = error ->
        if old && flow.drop?, do: delete(state, old.token_key)
        {error, notify(state, resource, before)}
    end
  end

  defp reply(flight, reply) do
    Enum.each(flight.waiters, &GenServer.reply(&1, reply))
    Enum.each(flight.queue, fn {_request, from} -> GenServer.reply(from, reply) end)
  end

  # The connection rotates its auth state whenever the access token changes.
  defp notify(state, resource, before) do
    listener = state.config.credential_listener

    if is_pid(listener) and credential(state, resource) != before,
      do: send(listener, :oauth_credentials_refreshed)

    state
  end

  defp credential(state, resource) do
    with %{} = context <- state.resources[resource],
         %{"access_token" => token} when is_binary(token) <- read(state, context) do
      token
    else
      _none -> nil
    end
  end

  defp read(%{store: {module, store}}, context), do: module.get(store, context.token_key)
  defp write(%{store: {module, store}}, key, token), do: :ok = module.put(store, key, token)
  defp delete(%{store: {module, store}}, key), do: :ok = module.delete(store, key)

  defp current?(%{"access_token" => token, "expires_at_ms" => nil}) when is_binary(token),
    do: true

  defp current?(%{"access_token" => token, "expires_at_ms" => expires_at})
       when is_binary(token) and is_integer(expires_at),
       do: expires_at > System.system_time(:millisecond) + @refresh_skew_ms

  defp current?(_token), do: false

  defp bearer(%{"access_token" => token}), do: "Bearer " <> token

  defp error(stage, reason), do: {:error, Error.exception(stage: stage, reason: reason)}
end
