defmodule FastestMCP.Client.Connection.Lifecycle do
  @moduledoc false
  # The connection's phase machine and negotiated session. `initialize` (MCP
  # 2025-11-25) moves :new through :initializing and `server/discover` (MCP
  # 2026-07-28) through :discovering to :initialized; session recovery passes
  # through :recovering; a failed negotiation is :failed. The caller that
  # negotiates is monitored, and readiness waiters are stored callers answered
  # by `reply_waiters/2` or by their deadline.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.Transport
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Extensions

  defstruct phase: :new,
            session_id: nil,
            initialize_result: nil,
            discovery_result: nil,
            protocol_version: nil,
            server_identity: nil,
            client_capabilities: nil,
            negotiation: nil,
            waiters: %{},
            session_generation: 0,
            auth_generation: 0,
            disconnecting?: false

  ## Negotiation

  def begin_initialize(%__MODULE__{phase: :new}, modern()) do
    {:error,
     invalid(
       "initialize is a legacy-only API and cannot be used with protocol_version: #{inspect(modern())}"
     )}
  end

  def begin_initialize(%__MODULE__{phase: :new} = lifecycle, _preference),
    do: {:ok, %{lifecycle | phase: :initializing, negotiation: %{kind: :initialize}}}

  def begin_initialize(lifecycle, _preference),
    do: {:error, invalid("initialize is invalid while client is #{lifecycle.phase}", lifecycle)}

  def begin_discover(_lifecycle, legacy()) do
    {:error,
     invalid(
       "server/discover is a modern-only API and cannot be used with protocol_version: #{inspect(legacy())}"
     )}
  end

  def begin_discover(%__MODULE__{negotiation: %{}}, _preference),
    do: {:error, invalid("server discovery is already in progress")}

  def begin_discover(%__MODULE__{phase: phase} = lifecycle, _preference)
      when phase in [:new, :initialized] do
    token = make_ref()

    previous =
      Map.take(lifecycle, [
        :phase,
        :discovery_result,
        :protocol_version,
        :session_id,
        :server_identity
      ])

    phase = if phase == :new, do: :discovering, else: phase
    negotiation = %{kind: :discover, token: token, previous: previous}
    {:ok, token, %{lifecycle | phase: phase, negotiation: negotiation}}
  end

  def begin_discover(lifecycle, _preference) do
    {:error, invalid("server discovery is invalid while client is #{lifecycle.phase}", lifecycle)}
  end

  def finish_initialize(%__MODULE__{phase: :initializing} = lifecycle) do
    {:ok,
     %{
       lifecycle
       | protocol_version: legacy(),
         server_identity: server_identity(lifecycle.initialize_result),
         phase: :initialized,
         negotiation: nil
     }}
  end

  def finish_initialize(lifecycle) do
    {:error,
     invalid("cannot finish initialization while client is #{lifecycle.phase}", lifecycle)}
  end

  def finish_discover(%__MODULE__{negotiation: %{token: token}} = lifecycle, token, result)
      when is_map(result) do
    supported = Map.get(result, "supportedVersions", [])

    if modern() in supported do
      {:ok,
       %{
         lifecycle
         | discovery_result: result,
           protocol_version: modern(),
           session_id: nil,
           server_identity: server_identity(result),
           phase: :initialized,
           negotiation: nil
       }}
    else
      {:error,
       %Error{
         code: :unsupported_protocol_version,
         message: "server discovery did not advertise MCP #{modern()}",
         details: %{supported: supported, requested: modern(), jsonrpc_code: -32022}
       }}
    end
  end

  def finish_discover(_lifecycle, _token, _result),
    do: {:error, invalid("server discovery attempt is no longer active")}

  def fail_initialize(lifecycle) do
    %{
      lifecycle
      | initialize_result: nil,
        client_capabilities: nil,
        phase: :failed,
        negotiation: nil
    }
  end

  # A failed or abandoned discovery restores what the connection had before.
  def fail_discover(
        %__MODULE__{negotiation: %{token: token, previous: previous}} = lifecycle,
        token
      ),
      do: {:ok, struct!(%{lifecycle | negotiation: nil}, previous)}

  def fail_discover(_lifecycle, _token), do: :stale

  ## Recovery

  def recovering(lifecycle), do: %{lifecycle | phase: :recovering}

  def recovered(lifecycle, %{initialize_result: result} = session) do
    %{
      lifecycle
      | session_id: session.session_id,
        initialize_result: result,
        client_capabilities: session.client_capabilities,
        server_identity: server_identity(result),
        phase: :initialized,
        session_generation: lifecycle.session_generation + 1
    }
  end

  def unrecovered(lifecycle) do
    %{
      lifecycle
      | session_id: nil,
        initialize_result: nil,
        client_capabilities: nil,
        phase: :failed
    }
  end

  ## Rules

  def check_request(%__MODULE__{phase: :initializing}, "initialize", :initialize), do: :ok

  def check_request(%__MODULE__{phase: phase}, "server/discover", _normalizer)
      when phase in [:new, :discovering, :initialized],
      do: :ok

  def check_request(%__MODULE__{phase: :initializing}, "ping", _normalizer), do: :ok

  def check_request(%__MODULE__{phase: :initialized}, method, _normalizer)
      when method != "initialize",
      do: :ok

  def check_request(lifecycle, method, _normalizer),
    do: {:error, error(lifecycle, if(method == "initialize", do: method, else: "send #{method}"))}

  def check_notification(%__MODULE__{phase: :initializing}, "notifications/initialized"), do: :ok

  def check_notification(%__MODULE__{phase: :initialized}, method)
      when method != "notifications/initialized",
      do: :ok

  def check_notification(lifecycle, method), do: {:error, error(lifecycle, "send #{method}")}

  def accepts_server_request?(%__MODULE__{phase: :initialized}, _method), do: true
  def accepts_server_request?(%__MODULE__{phase: :initializing}, "ping"), do: true
  def accepts_server_request?(_lifecycle, _method), do: false

  def supports?(_lifecycle, _extensions, method) when method in ["initialize", "server/discover"],
    do: true

  def supports?(%__MODULE__{protocol_version: modern()} = lifecycle, extensions, method)
      when method in ["tasks/get", "tasks/update", "tasks/cancel"] do
    Extensions.enabled?(server_capabilities(lifecycle), Extensions.tasks()) and
      Extensions.enabled?(extensions, Extensions.tasks())
  end

  def supports?(lifecycle, _extensions, method),
    do: Protocol.server_supports_method?(server_capabilities(lifecycle), method)

  def server_capabilities(lifecycle),
    do:
      Map.get(
        lifecycle.discovery_result || lifecycle.initialize_result || %{},
        "capabilities",
        %{}
      )

  # What a caller needs to run a call: the negotiated protocol and server
  # capabilities, the transport type, and the handlers that answer input
  # requests.
  def snapshot(%State{config: config, lifecycle: lifecycle} = state) do
    config
    |> Map.take([
      :roots,
      :sampling_handler,
      :sampling_tools,
      :sampling_context,
      :elicitation_handler,
      :url_elicitation_handler,
      :schema_options,
      :max_mrtr_rounds
    ])
    |> Map.merge(%{
      protocol_version: lifecycle.protocol_version,
      capabilities: server_capabilities(lifecycle),
      tasks?: supports?(lifecycle, config.extensions, "tasks/cancel"),
      transport: state.transport.type
    })
  end

  def put_client_capabilities(lifecycle, %{"method" => "initialize"} = envelope),
    do: %{lifecycle | client_capabilities: get_in(envelope, ["params", "capabilities"]) || %{}}

  def put_client_capabilities(lifecycle, _envelope), do: lifecycle

  def error(lifecycle, action) do
    invalid("cannot #{action} while client is #{lifecycle.phase}", lifecycle)
  end

  def readiness_error(lifecycle) do
    %Error{
      code: :internal_error,
      message: "MCP client failed to become ready",
      details: %{lifecycle_state: lifecycle.phase}
    }
  end

  defp server_identity(%{"serverInfo" => server_info}) when is_map(server_info), do: server_info

  defp server_identity(%{"_meta" => %{} = meta}),
    do: Map.get(meta, "io.modelcontextprotocol/serverInfo")

  defp server_identity(_result), do: nil

  defp invalid(message, lifecycle \\ nil) do
    details = if lifecycle, do: %{lifecycle_state: lifecycle.phase}, else: %{}
    %Error{code: :invalid_request, message: message, details: details}
  end

  ## Readiness

  def ready?(%State{} = state),
    do: state.lifecycle.phase == :initialized and Transport.connected?(state.transport)

  def release(state), do: if(ready?(state), do: reply_waiters(state, :ok), else: state)

  def add_waiter(%State{} = state, {pid, _tag} = from, timeout) do
    {ref, state} = State.monitor(state, pid, {:ready_waiter, from})

    timer =
      if timeout != :infinity, do: Process.send_after(self(), {:ready_timeout, from}, timeout)

    put_in(state.lifecycle.waiters[from], {ref, timer})
  end

  def reply_waiters(%State{} = state, reply) do
    Enum.reduce(state.lifecycle.waiters, put_in(state.lifecycle.waiters, %{}), fn
      {from, waiter}, state -> reply_waiter(state, from, waiter, reply)
    end)
  end

  # A waiter whose deadline passed gets `reply`; one that exited gets none.
  def drop_waiter(%State{} = state, from, reply) do
    case Map.pop(state.lifecycle.waiters, from) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        reply_waiter(put_in(state.lifecycle.waiters, waiters), from, waiter, reply)
    end
  end

  defp reply_waiter(state, from, {ref, timer}, reply) do
    Outbound.cancel_timer(timer)
    if reply, do: GenServer.reply(from, reply)
    State.demonitor(state, ref)
  end
end
