defmodule FastestMCP.Client.Connection do
  @moduledoc false
  use GenServer
  alias FastestMCP.Client
  alias FastestMCP.BackgroundTask
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.OAuth.Error, as: OAuthError
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.ResponseCache
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Client.Transport, as: ClientTransport
  alias FastestMCP.Client.Transport.InProcess, as: InProcessClientTransport
  alias FastestMCP.Client.Transport.Stdio, as: StdioClientTransport
  alias FastestMCP.Client.Transport.StreamableHTTP, as: HTTPClientTransport
  alias FastestMCP.Client.URLElicitation
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.JSONValue
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.Subscriptions
  alias FastestMCP.Root
  alias FastestMCP.Schema
  alias FastestMCP.TaskId
  alias FastestMCP.TaskWire
  alias FastestMCP.Telemetry
  alias FastestMCP.Transport.JSONRPC

  @default_timeout_ms 5000
  @default_init_timeout_ms 10000
  @default_http_max_in_flight 10
  @default_stdio_max_in_flight 1
  @default_modern_stdio_max_in_flight 10
  @default_max_mrtr_rounds 8
  @default_sse_retry_ms 1000
  @default_sse_max_retry_ms 30000
  @default_sse_max_reconnect_attempts 3
  @default_max_response_bytes 16 * 1024 * 1024
  @default_stdio_restart_retry_ms 1000
  @default_stdio_restart_max_retry_ms 30000
  @default_stdio_restart_max_attempts 3
  @default_max_auth_attempts 3
  @default_max_callback_request_ids 100_000

  @type ref :: Client.ref()
  @doc "Starts a supervised MCP client from a keyword configuration."
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :target) do
        {:ok, target} ->
          name = Keyword.get(opts, :name)
          client_opts = Keyword.drop(opts, [:target, :name, :id])
          start_and_negotiate(target, client_opts, name)

        :error ->
          raise ArgumentError, "client start_link/1 requires a :target option"
      end
    else
      raise ArgumentError, "client start options must be a keyword list"
    end
  end

  def start_link(other) do
    raise ArgumentError, "client start options must be a keyword list, got: #{inspect(other)}"
  end

  @doc "Returns a worker specification for a supervised MCP client."
  def child_spec(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "client child options must be a keyword list"
    end

    restart = normalize_child_restart!(Keyword.get(opts, :restart, :permanent))
    start_opts = opts |> Keyword.delete(:id) |> Keyword.delete(:restart)

    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, Client)),
      start: {Client, :start_link, [start_opts]},
      restart: restart,
      shutdown: 20000,
      type: :worker
    }
  end

  def child_spec(other) do
    raise ArgumentError, "client child options must be a keyword list, got: #{inspect(other)}"
  end

  defp normalize_child_restart!(restart) when restart in [:permanent, :transient, :temporary] do
    restart
  end

  defp normalize_child_restart!(restart) do
    raise ArgumentError,
          "client child restart must be :permanent, :transient, or :temporary, got: #{inspect(restart)}"
  end

  @doc "Connects a client to the given transport target."
  def connect(target, opts \\ []) do
    case start_and_negotiate(target, opts, Keyword.get(opts, :name)) do
      {:ok, pid} -> {:ok, %Client{pid: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_and_negotiate(target, opts, name) do
    with :ok <- validate_protocol_options(opts),
         {:ok, transport} <- normalize_transport(target, opts),
         {:ok, pid} <- start_client_process(transport, opts, name) do
      client = %Client{pid: pid}

      try do
        if Keyword.get(opts, :auto_initialize, true) do
          _ = negotiate_ready(client, opts)

          if Keyword.get(opts, :session_stream, false) and
               protocol_version(client) == "2025-11-25" do
            open_session_stream(client)
          end
        end

        {:ok, pid}
      rescue
        error in [Error, ProtocolError] ->
          stop_failed_client(pid)
          {:error, error}
      catch
        kind, reason ->
          stop_failed_client(pid)
          {:error, {kind, reason}}
      end
    end
  end

  defp start_client_process(transport, opts, nil) do
    GenServer.start_link(__MODULE__, {transport, opts})
  end

  defp start_client_process(transport, opts, name) do
    GenServer.start_link(__MODULE__, {transport, opts}, name: name)
  end

  defp stop_failed_client(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid, :shutdown)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Connects a client to the given transport target and raises on failure."
  def connect!(target, opts \\ []) do
    FastestMCP.OperationResult.unwrap!(connect(target, opts))
  end

  @doc "Disconnects a client and releases its transport resources."
  def disconnect(client_ref) do
    disconnect_with_evidence(client_ref)
  end

  @doc "Disconnects only after the transport proves its resources are released."
  @spec disconnect_with_evidence(ref()) :: :ok | {:error, term()}
  def disconnect_with_evidence(client_ref) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, :disconnect_with_evidence, 5000)
  end

  @doc "Returns whether the client process is still alive."
  def connected?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %Client{pid: pid}} -> Process.alive?(pid)
      :error -> false
    end
  end

  @doc "Returns whether the client has completed negotiation and its transport is usable."
  def ready?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %Client{pid: pid}} ->
        GenServer.call(pid, :ready?)

      :error ->
        false
    end
  catch
    :exit, _reason -> false
  end

  @doc "Waits until a client is ready or raises a normalized timeout or connection error."
  def await_ready(client_ref, timeout \\ @default_init_timeout_ms)

  def await_ready(client_ref, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    deadline =
      if timeout == :infinity do
        :infinity
      else
        monotonic_ms() + timeout
      end

    follow_name? = not match?(%Client{}, client_ref) and not is_pid(client_ref)
    do_await_ready(client_ref, deadline, follow_name?)
  end

  def await_ready(_client_ref, timeout) do
    raise ArgumentError,
          "ready timeout must be :infinity or a non-negative integer, got: #{inspect(timeout)}"
  end

  @doc "Returns the negotiated session id."
  def session_id(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :session_id)
  end

  @doc "Returns the last initialize result cached by the client."
  def initialize_result(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :initialize_result)
  end

  @doc "Returns the last modern server discovery result cached by the client."
  def discovery_result(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :discovery_result)
  end

  @doc false
  def lifecycle_state(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :lifecycle_state)
  end

  @doc "Returns the negotiated protocol version."
  def protocol_version(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :protocol_version)
  end

  @doc "Returns the negotiated server capabilities."
  def capabilities(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :capabilities)
  end

  @doc "Returns whether the client session stream is currently open."
  def session_stream_open?(client_ref) do
    GenServer.call(pin_client!(client_ref).pid, :session_stream_open?)
  end

  @doc "Registers the sampling callback used for server-initiated sampling requests."
  def set_sampling_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :sampling_handler, handler})
  end

  @doc "Registers the elicitation callback used for server-initiated interaction requests."
  def set_elicitation_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :elicitation_handler, handler})
  end

  @doc "Registers the callback used for URL-mode elicitation requests."
  def set_url_elicitation_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :url_elicitation_handler, handler})
  end

  @doc "Registers the callback for completion of an accepted URL elicitation."
  def set_elicitation_complete_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :elicitation_complete_handler, handler})
  end

  @doc "Registers the callback used for server log messages."
  def set_log_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :log_handler, handler})
  end

  @doc "Registers the callback used for progress notifications."
  def set_progress_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :progress_handler, handler})
  end

  @doc "Registers the callback used for generic notifications."
  def set_notification_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :notification_handler, handler})
  end

  @doc "Replaces the access token used for future requests."
  def set_access_token(client_ref, token) when is_binary(token) or is_nil(token) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_access_token, token})
  end

  @doc "Merges or replaces auth input used for future requests."
  def set_auth_input(client_ref, auth_input) when is_map(auth_input) or is_list(auth_input) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:replace_auth_input, auth_input})
  end

  @doc "Replaces the advertised filesystem roots and notifies the server on material changes."
  def set_roots(client_ref, roots) when is_list(roots) do
    %Client{pid: pid} = pin_client!(client_ref)

    case GenServer.call(pid, {:set_roots, roots}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Opens the session event stream when the transport supports it."
  def open_session_stream(client_ref, opts \\ []) do
    %Client{pid: pid} = pin_client!(client_ref)

    case GenServer.call(pid, {:open_session_stream, opts}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Closes the session event stream."
  def close_session_stream(client_ref) do
    %Client{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, :close_session_stream)
  end

  @doc false
  def pin(client_ref) do
    pin_client!(client_ref)
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({transport, opts}) do
    with :ok <- validate_protocol_options(opts),
         {:ok, roots} <- FastestMCP.Client.Codec.normalize_client_roots(Keyword.get(opts, :roots)) do
      protocol_preference =
        FastestMCP.Client.Codec.normalize_protocol_preference!(
          Keyword.get(opts, :protocol_version, :auto)
        )

      state =
        %FastestMCP.Client.State{
          client_pid: self(),
          transport: transport,
          session_id: transport.session_id,
          initialize_result: nil,
          discovery_result: nil,
          protocol_preference: protocol_preference,
          selected_protocol_version: nil,
          extensions:
            opts
            |> Keyword.get(:extensions)
            |> Extensions.declare_oauth_grant(Keyword.get(opts, :oauth)),
          max_mrtr_rounds:
            normalize_positive_integer!(
              Keyword.get(opts, :max_mrtr_rounds, @default_max_mrtr_rounds),
              :max_mrtr_rounds
            ),
          advertised_client_capabilities: nil,
          schema_options:
            FastestMCP.Client.Catalog.normalize_schema_options!(
              Keyword.get(opts, :schema_options, [])
            ),
          server_identity: nil,
          max_recovery_queue: 128,
          next_request_id: 1,
          max_response_bytes:
            FastestMCP.Client.Codec.validate_max_response_bytes!(
              Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
            ),
          sampling_handler: Keyword.get(opts, :sampling_handler),
          sampling_tools:
            FastestMCP.Client.Codec.normalize_sampling_tools(
              Keyword.get(opts, :sampling_tools, [])
            ),
          sampling_context: Keyword.get(opts, :sampling_context),
          elicitation_handler: Keyword.get(opts, :elicitation_handler),
          url_elicitation_handler: Keyword.get(opts, :url_elicitation_handler),
          elicitation_complete_handler: Keyword.get(opts, :elicitation_complete_handler),
          log_handler: Keyword.get(opts, :log_handler),
          progress_handler: Keyword.get(opts, :progress_handler),
          notification_handler: Keyword.get(opts, :notification_handler),
          client_info: normalize_client_info(Keyword.get(opts, :client_info)),
          auth_input: FastestMCP.Client.Codec.normalize_request_auth_opts(opts),
          legacy_stdio_auth_metadata?: Keyword.get(opts, :legacy_stdio_auth_metadata, false),
          worker_supervisor: nil,
          max_callback_request_ids:
            FastestMCP.Client.Codec.validate_max_callback_request_ids!(
              Keyword.get(
                opts,
                :max_callback_request_ids,
                @default_max_callback_request_ids
              )
            ),
          roots: roots,
          roots_supported?: is_list(roots),
          session_stream: nil,
          max_sse_event_bytes:
            FastestMCP.Client.Codec.validate_max_sse_event_bytes!(
              Keyword.get(opts, :max_sse_event_bytes, 1_048_576)
            ),
          sse_reconnect: normalize_sse_reconnect!(Keyword.get(opts, :sse_reconnect, [])),
          oauth: nil,
          timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
          max_in_flight:
            Keyword.get_lazy(opts, :max_in_flight, fn ->
              default_max_in_flight(transport.type, protocol_preference)
            end),
          pending: %FastestMCP.Client.State.Pending{
            in_flight: %{},
            worker_refs: %{},
            request_owner_refs: %{}
          },
          callbacks: %FastestMCP.Client.State.Callbacks{
            callback_task_refs: %{},
            callback_result_waiters: %{},
            callback_tasks: %{},
            callback_requests: %{},
            callback_worker_refs: %{},
            callback_request_ids: MapSet.new(),
            pending_url_elicitations: %{}
          },
          stdio: %FastestMCP.Client.State.Stdio{
            pending_stdio_buffer: "",
            pending_stdio_ref: nil,
            pending_stdio_refs: %{},
            stdio_restart: normalize_stdio_restart!(Keyword.get(opts, :stdio_restart, true)),
            stdio_restart_attempt: 0,
            stdio_restart_timer_ref: nil,
            stdio_restart_token: nil
          },
          catalog: %FastestMCP.Client.State.Catalog{
            tool_catalog: ToolCatalog.new(),
            tool_catalog_ready?: false,
            tool_catalog_load: nil,
            response_cache: ResponseCache.new(Keyword.get(opts, :response_cache, false))
          },
          tasks: %FastestMCP.Client.State.Tasks{task_registry: %{}},
          lifecycle: %FastestMCP.Client.State.Lifecycle{
            lifecycle_state: :new,
            initialization_owner_ref: nil,
            discovery_attempt: nil,
            readiness_waiters: %{},
            readiness_owner_refs: %{},
            auth_generation: 0,
            session_generation: 0,
            recovery: nil,
            disconnecting?: false
          }
        }

      case validate_transport_options(state) do
        :ok ->
          case Task.Supervisor.start_link() do
            {:ok, worker_supervisor} ->
              state = %{state | worker_supervisor: worker_supervisor}

              case maybe_start_oauth(state, Keyword.get(opts, :oauth)) do
                {:ok, state} -> open_client_transport(state)
                {:error, %Error{} = error} -> {:stop, error}
              end

            {:error, reason} ->
              {:stop, reason}
          end

        {:error, %Error{} = error} ->
          {:stop, error}
      end
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:disconnect_with_evidence, _from, state) do
    case retire_client_transport(state) do
      {:ok, retired_state} ->
        {:stop, :normal, :ok, retired_state}

      {:error, reason, retained_state} ->
        {:reply, {:error, reason},
         %{retained_state | lifecycle: %{retained_state.lifecycle | disconnecting?: true}}}
    end
  end

  def handle_call(
        :initialize_result,
        _from,
        %{lifecycle: %{lifecycle_state: :initialized}} = state
      ) do
    {:reply, state.initialize_result, state}
  end

  def handle_call(:initialize_result, _from, state) do
    {:reply, nil, state}
  end

  def handle_call(:discovery_result, _from, state) do
    {:reply, state.discovery_result, state}
  end

  def handle_call(:protocol_version, _from, state) do
    {:reply, state.selected_protocol_version, state}
  end

  def handle_call(:transport_type, _from, state) do
    {:reply, state.transport.type, state}
  end

  def handle_call(:capabilities, _from, state) do
    result = state.discovery_result || state.initialize_result || %{}
    {:reply, Map.get(result, "capabilities", %{}), state}
  end

  def handle_call(:tasks_negotiated?, _from, state) do
    {:reply, server_supports_method?(state, "tasks/cancel"), state}
  end

  def handle_call(:mrtr_snapshot, _from, state) do
    snapshot =
      Map.take(
        state,
        [
          :roots,
          :roots_supported?,
          :sampling_handler,
          :sampling_tools,
          :sampling_context,
          :elicitation_handler,
          :url_elicitation_handler,
          :schema_options,
          :max_mrtr_rounds
        ]
      )

    {:reply, snapshot, state}
  end

  def handle_call(:lifecycle_state, _from, state) do
    {:reply, state.lifecycle.lifecycle_state, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, client_ready?(state), state}
  end

  def handle_call({:await_ready, owner, token}, _from, state) do
    cond do
      client_ready?(state) ->
        {:reply, :ready, state}

      state.lifecycle.lifecycle_state == :failed ->
        {:reply, {:error, readiness_error(state)}, state}

      true ->
        owner_ref = Process.monitor(owner)
        waiter = %{owner: owner, owner_ref: owner_ref}

        {:reply, :waiting,
         %{
           state
           | lifecycle: %{
               state.lifecycle
               | readiness_waiters: Map.put(state.lifecycle.readiness_waiters, token, waiter),
                 readiness_owner_refs:
                   Map.put(state.lifecycle.readiness_owner_refs, owner_ref, token)
             }
         }}
    end
  end

  def handle_call(
        :begin_initialize,
        {owner, _tag},
        %{lifecycle: %{lifecycle_state: :new}} = state
      ) do
    if state.protocol_preference == "2026-07-28" do
      {:reply,
       {:error,
        %Error{
          code: :invalid_request,
          message:
            "initialize is a legacy-only API and cannot be used with protocol_version: \"2026-07-28\""
        }}, state}
    else
      owner_ref = Process.monitor(owner)

      {:reply, :ok,
       %{
         state
         | lifecycle: %{
             state.lifecycle
             | lifecycle_state: :initializing,
               initialization_owner_ref: owner_ref
           }
       }}
    end
  end

  def handle_call(:begin_initialize, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message: "initialize is invalid while client is #{state.lifecycle.lifecycle_state}",
        details: %{lifecycle_state: state.lifecycle.lifecycle_state}
      }}, state}
  end

  def handle_call(:begin_discover, {owner, _tag}, state) do
    cond do
      state.protocol_preference == "2025-11-25" ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message:
              "server/discover is a modern-only API and cannot be used with protocol_version: \"2025-11-25\""
          }}, state}

      not is_nil(state.lifecycle.discovery_attempt) ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message: "server discovery is already in progress"
          }}, state}

      state.lifecycle.lifecycle_state not in [:new, :initialized] ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message:
              "server discovery is invalid while client is #{state.lifecycle.lifecycle_state}",
            details: %{lifecycle_state: state.lifecycle.lifecycle_state}
          }}, state}

      true ->
        token = make_ref()
        owner_ref = Process.monitor(owner)

        attempt = %{
          token: token,
          owner_ref: owner_ref,
          previous_lifecycle: state.lifecycle.lifecycle_state,
          previous_discovery_result: state.discovery_result,
          previous_protocol_version: state.selected_protocol_version,
          previous_session_id: state.session_id,
          previous_server_identity: state.server_identity
        }

        lifecycle_state =
          if state.lifecycle.lifecycle_state == :new do
            :discovering
          else
            state.lifecycle.lifecycle_state
          end

        {:reply, {:ok, token},
         %{
           state
           | lifecycle: %{
               state.lifecycle
               | lifecycle_state: lifecycle_state,
                 discovery_attempt: attempt
             }
         }}
    end
  end

  def handle_call(
        :finish_initialize,
        _from,
        %{lifecycle: %{lifecycle_state: :initializing}} = state
      ) do
    demonitor_initialization_owner(state.lifecycle.initialization_owner_ref)

    next_state = %{
      state
      | selected_protocol_version: "2025-11-25",
        server_identity: server_identity(state.initialize_result),
        lifecycle: %{
          state.lifecycle
          | lifecycle_state: :initialized,
            initialization_owner_ref: nil
        }
    }

    next_state = maybe_invalidate_connection_cache(state, next_state)

    {:reply, :ok, release_ready_waiters(next_state)}
  end

  def handle_call(
        {:finish_discover, token, %{} = result},
        _from,
        %{lifecycle: %{discovery_attempt: %{token: token} = attempt}} = state
      ) do
    supported = Map.get(result, "supportedVersions", [])

    if "2026-07-28" in supported do
      demonitor_initialization_owner(attempt.owner_ref)

      next_state = %{
        state
        | discovery_result: result,
          selected_protocol_version: "2026-07-28",
          session_id: nil,
          server_identity: server_identity(result),
          lifecycle: %{state.lifecycle | lifecycle_state: :initialized, discovery_attempt: nil}
      }

      next_state = maybe_invalidate_connection_cache(state, next_state)

      {:reply, :ok, release_ready_waiters(next_state)}
    else
      {:reply,
       {:error,
        %Error{
          code: :unsupported_protocol_version,
          message: "server discovery did not advertise MCP 2026-07-28",
          details: %{supported: supported, requested: "2026-07-28", jsonrpc_code: -32022}
        }}, state}
    end
  end

  def handle_call({:finish_discover, _token, _result}, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message: "server discovery attempt is no longer active"
      }}, state}
  end

  def handle_call(:finish_initialize, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message:
          "cannot finish initialization while client is #{state.lifecycle.lifecycle_state}",
        details: %{lifecycle_state: state.lifecycle.lifecycle_state}
      }}, state}
  end

  def handle_call({:fail_initialize, _reason}, _from, state) do
    demonitor_initialization_owner(state.lifecycle.initialization_owner_ref)

    next_state =
      %{
        state
        | initialize_result: nil,
          advertised_client_capabilities: nil,
          lifecycle: %{state.lifecycle | lifecycle_state: :failed, initialization_owner_ref: nil}
      }

    {:reply, :ok, fail_ready_waiters(next_state, readiness_error(next_state))}
  end

  def handle_call(
        {:fail_discover, token, _reason},
        _from,
        %{lifecycle: %{discovery_attempt: %{token: token} = attempt}} = state
      ) do
    demonitor_initialization_owner(attempt.owner_ref)

    {:reply, :ok,
     %{
       state
       | discovery_result: attempt.previous_discovery_result,
         selected_protocol_version: attempt.previous_protocol_version,
         session_id: attempt.previous_session_id,
         server_identity: attempt.previous_server_identity,
         lifecycle: %{
           state.lifecycle
           | lifecycle_state: attempt.previous_lifecycle,
             discovery_attempt: nil
         }
     }}
  end

  def handle_call({:fail_discover, _token, _reason}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:session_stream_open?, _from, state) do
    {:reply, session_stream_started?(state), state}
  end

  def handle_call({:set_handler, key, handler}, _from, state) do
    case FastestMCP.Client.Codec.validate_handler_transition(state, key, handler) do
      :ok -> {:reply, :ok, Map.put(state, key, handler)}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:set_roots, roots}, _from, state) do
    with true <- state.roots_supported?,
         {:ok, normalized} <- FastestMCP.Client.Codec.normalize_client_roots(roots) do
      if normalized == state.roots do
        {:reply, :ok, state}
      else
        next_state =
          state
          |> Map.put(:roots, normalized)
          |> invalidate_client_caches(:roots_changed)

        result =
          if state.initialize_result do
            FastestMCP.Client.Requests.send_client_notification(
              next_state,
              "notifications/roots/list_changed",
              %{},
              []
            )
          else
            :ok
          end

        case result do
          :ok -> {:reply, :ok, next_state}
          {:error, %Error{} = error} -> {:reply, {:error, error}, state}
        end
      end
    else
      false ->
        {:reply,
         {:error,
          %Error{
            code: :bad_request,
            message: "roots support must be configured before initialization"
          }}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:callback_cancelled?, request_id, task_id}, _from, state) do
    cancelled? =
      if is_binary(task_id) do
        match?(%{status: :cancelled}, Map.get(state.callbacks.callback_tasks, task_id))
      else
        match?(%{cancelled?: true}, Map.get(state.callbacks.callback_requests, request_id))
      end

    {:reply, cancelled?, state}
  end

  def handle_call({:report_callback_progress, context, progress, opts}, _from, state) do
    with {:ok, params, callbacks} <-
           FastestMCP.Client.CallbackProgress.prepare(state.callbacks, context, progress, opts),
         :ok <-
           FastestMCP.Client.Requests.send_client_notification(
             state,
             "notifications/progress",
             params,
             opts
           ) do
      {:reply, :ok, %{state | callbacks: callbacks}}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:replace_auth_input, auth_input}, _from, state) do
    next_state =
      state
      |> Map.put(
        :auth_input,
        FastestMCP.Client.Codec.normalize_request_auth_opts(auth_input: auth_input)
      )
      |> rotate_auth_partition()

    {:reply, :ok, next_state}
  end

  def handle_call({:set_access_token, token}, _from, state) do
    next_state =
      state
      |> Map.put(
        :auth_input,
        FastestMCP.Client.Codec.put_authorization(
          state.auth_input,
          FastestMCP.Client.Codec.bearer_authorization(token)
        )
      )
      |> rotate_auth_partition()

    {:reply, :ok, next_state}
  end

  def handle_call({:merge_auth_input, auth_input}, _from, state) do
    merged =
      state
      |> Map.get(:auth_input, %{})
      |> FastestMCP.Client.Codec.merge_auth_inputs(
        FastestMCP.Client.Codec.normalize_request_auth_opts(auth_input: auth_input)
      )

    {:reply, :ok, state |> Map.put(:auth_input, merged) |> rotate_auth_partition()}
  end

  def handle_call(
        {:notification, method, params, opts},
        from,
        %{lifecycle: %{lifecycle_state: :recovering}} = state
      ) do
    FastestMCP.Client.HTTP.enqueue_recovery_operation(
      state,
      {:notification, from, method, params, opts}
    )
  end

  def handle_call({:notification, method, params, opts}, from, state) do
    with :ok <- validate_request_budget({:sync, from}, opts),
         :ok <- validate_outbound_notification_lifecycle(state, method) do
      {:reply, FastestMCP.Client.Requests.send_client_notification(state, method, params, opts),
       state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:register_task, task_id, kind, target, output_validator}, _from, state) do
    task_id = to_string(task_id)

    entry =
      state.tasks.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:status, nil)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> Map.put_new(:progress_token, nil)
      |> Map.put_new(:progress_handler, nil)
      |> Map.put_new(:last_progress, nil)
      |> Map.put_new(:progress_total, nil)
      |> Map.put(:kind, kind)
      |> Map.put(:target, target)
      |> Map.put_new(:origin_method, FastestMCP.Client.Execution.origin_method_for_kind(kind))
      |> FastestMCP.Client.Catalog.maybe_put_task_output_validator(output_validator)

    state = %{
      state
      | tasks: %{state.tasks | task_registry: Map.put(state.tasks.task_registry, task_id, entry)}
    }

    {:reply,
     %RemoteTask{client: %Client{pid: self()}, task_id: task_id, kind: kind, target: target},
     FastestMCP.Client.Execution.maybe_start_legacy_task_session_stream(state)}
  end

  def handle_call({:cached_task_status, task_id}, _from, state) do
    {:reply, get_in(state.tasks.task_registry, [task_id, :status]), state}
  end

  def handle_call({:cache_task_status, task_id, task}, _from, state) do
    {:reply, :ok, update_task_status(state, task_id, task)}
  end

  def handle_call({:cached_task_result, task_id}, _from, state) do
    case get_in(state.tasks.task_registry, [task_id, :result]) do
      nil -> {:reply, :error, state}
      result -> {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:task_origin_method, task_id}, _from, state) do
    {:reply, get_in(state.tasks.task_registry, [to_string(task_id), :origin_method]), state}
  end

  def handle_call({:task_validation, task_id}, _from, state) do
    entry = Map.get(state.tasks.task_registry, to_string(task_id), %{})
    {:reply, {entry[:origin_method], entry[:output_validator]}, state}
  end

  def handle_call(:catalog_configuration, _from, state),
    do: {:reply, {state.catalog.tool_catalog.generation, state.schema_options}, state}

  def handle_call(:catalog_revision, _from, state) do
    {:reply,
     %{
       generation: state.catalog.tool_catalog.generation,
       fresh?:
         state.catalog.tool_catalog_ready? and ToolCatalog.fresh?(state.catalog.tool_catalog),
       ready?: client_ready?(state)
     }, state}
  end

  def handle_call({:ensure_tool_catalog, mode}, from, state) do
    state =
      if mode in [:refresh, :bypass] and is_nil(state.catalog.tool_catalog_load) do
        invalidate_client_caches(state, :explicit_refresh)
      else
        state
      end

    handle_call(:ensure_tool_catalog, from, state)
  end

  def handle_call(:ensure_tool_catalog, from, %{catalog: %{tool_catalog_ready?: true}} = state) do
    if ToolCatalog.fresh?(state.catalog.tool_catalog) do
      {:reply, {:ready, state.catalog.tool_catalog}, state}
    else
      handle_call(:ensure_tool_catalog, from, %{
        state
        | catalog: %{state.catalog | tool_catalog_ready?: false}
      })
    end
  end

  def handle_call(
        :ensure_tool_catalog,
        {loader, _tag},
        %{catalog: %{tool_catalog_load: nil}} = state
      ) do
    monitor_ref = Process.monitor(loader)
    generation = state.catalog.tool_catalog.generation

    {:reply, {:load, generation, state.schema_options},
     %{
       state
       | catalog: %{
           state.catalog
           | tool_catalog_load: %{
               loader: loader,
               monitor_ref: monitor_ref,
               generation: generation,
               waiters: []
             }
         }
     }}
  end

  def handle_call(:ensure_tool_catalog, from, state) do
    {:noreply, update_in(state.catalog.tool_catalog_load.waiters, &[from | &1])}
  end

  def handle_call(
        {:install_tool_catalog, generation, result},
        {loader, _tag},
        %{catalog: %{tool_catalog_load: %{loader: loader, generation: generation} = load}} = state
      ) do
    Process.demonitor(load.monitor_ref, [:flush])

    case result do
      {:ok, %ToolCatalog{} = catalog} ->
        Enum.each(load.waiters, &GenServer.reply(&1, {:ready, catalog}))

        {:reply, {:ready, catalog},
         %{
           state
           | catalog: %{
               state.catalog
               | tool_catalog: catalog,
                 tool_catalog_ready?: true,
                 tool_catalog_load: nil
             }
         }}

      {:error, exception} when is_exception(exception) ->
        Enum.each(load.waiters, &GenServer.reply(&1, {:error, exception}))

        {:reply, {:error, exception},
         %{state | catalog: %{state.catalog | tool_catalog_load: nil}}}
    end
  end

  def handle_call({:install_tool_catalog, _generation, _result}, _from, state) do
    {:reply, :stale, state}
  end

  def handle_call({:cache_task_result, task_id, outcome}, _from, state) do
    entry =
      state.tasks.task_registry
      |> Map.get(task_id, %{})
      |> Map.put(:result, outcome)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> clear_task_progress()

    {:reply, :ok, put_in(state.tasks.task_registry[task_id], entry)}
  end

  def handle_call({:register_task_callback, task_id, callback}, _from, state) do
    callback_ref = make_ref()

    entry =
      state.tasks.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:status, nil)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> update_in([Access.key(:callbacks)], &Map.put(&1, callback_ref, callback))

    {:reply, callback_ref, put_in(state.tasks.task_registry[task_id], entry)}
  end

  def handle_call({:wait_task_notification, task_id, target_statuses, timeout_ms}, from, state) do
    state = FastestMCP.Client.Execution.maybe_start_legacy_task_session_stream(state)

    case get_in(state.tasks.task_registry, [task_id, :status]) do
      %{} = status ->
        if FastestMCP.Client.Execution.task_matches_target_status?(status, target_statuses) do
          {:reply, {:ok, status}, state}
        else
          waiter_ref = make_ref()

          timer_ref =
            Process.send_after(self(), {:task_wait_timeout, task_id, waiter_ref}, timeout_ms)

          entry =
            state.tasks.task_registry
            |> Map.get(task_id, %{})
            |> Map.put_new(:status, nil)
            |> Map.put_new(:result, nil)
            |> Map.put_new(:callbacks, %{})
            |> Map.put_new(:waiters, %{})
            |> update_in(
              [Access.key(:waiters)],
              &Map.put(&1, waiter_ref, %{
                from: from,
                target_statuses: target_statuses,
                timer_ref: timer_ref
              })
            )

          {:noreply, put_in(state.tasks.task_registry[task_id], entry)}
        end

      _other ->
        waiter_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:task_wait_timeout, task_id, waiter_ref}, timeout_ms)

        entry =
          state.tasks.task_registry
          |> Map.get(task_id, %{})
          |> Map.put_new(:status, nil)
          |> Map.put_new(:result, nil)
          |> Map.put_new(:callbacks, %{})
          |> Map.put_new(:waiters, %{})
          |> update_in(
            [Access.key(:waiters)],
            &Map.put(&1, waiter_ref, %{
              from: from,
              target_statuses: target_statuses,
              timer_ref: timer_ref
            })
          )

        {:noreply, put_in(state.tasks.task_registry[task_id], entry)}
    end
  end

  def handle_call(
        {:open_session_stream, _opts},
        _from,
        %{transport: %{type: type}} = state
      )
      when type in [:stdio, :in_process] do
    {:reply,
     {:error,
      %Error{
        code: :bad_request,
        message: "session streams are only supported for streamable HTTP clients"
      }}, state}
  end

  def handle_call({:open_session_stream, _opts}, from, state) do
    cond do
      state.lifecycle.lifecycle_state != :initialized ->
        {:reply, {:error, lifecycle_error(state, "open a session stream")}, state}

      session_stream_started?(state) ->
        {:reply, :ok, state}

      session_stream_alive?(state) ->
        {:noreply,
         update_in(state, [Access.key(:session_stream), :waiters], &[from | List.wrap(&1)])}

      true ->
        parent = self()
        stream_ref = make_ref()

        snapshot = FastestMCP.Client.TransportSnapshot.new(state)

        {pid, monitor_ref} =
          FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
            FastestMCP.Client.HTTP.run_session_stream(parent, stream_ref, snapshot)
          end)

        {:noreply,
         %{
           state
           | session_stream: %{
               pid: pid,
               monitor_ref: monitor_ref,
               stream_ref: stream_ref,
               request_ref: nil,
               started?: false,
               waiters: [from]
             }
         }}
    end
  end

  def handle_call(:close_session_stream, _from, state) do
    if session_stream = state.session_stream do
      FastestMCP.Client.HTTP.cancel_http_request(session_stream.request_ref)

      if is_pid(session_stream.pid) do
        Process.exit(session_stream.pid, :kill)
      end

      if session_stream.monitor_ref do
        Process.demonitor(session_stream.monitor_ref, [:flush])
      end

      state =
        reply_session_stream_waiters(
          %{state | session_stream: nil},
          {:error,
           %Error{
             code: :bad_request,
             message: "session stream closed before opening"
           }},
          session_stream.waiters
        )

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(
        {:recover_stream_session, stream_ref, stale_session_id, original_error},
        from,
        state
      ) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) and
         state.session_id == stale_session_id do
      {:noreply, begin_stream_session_recovery(state, from, original_error)}
    else
      {:reply,
       {:error,
        %Error{
          code: :bad_request,
          message: "session stream recovery was superseded"
        }}, state}
    end
  end

  def handle_call({:handle_server_request, message, opts}, _from, state) do
    case process_server_request(message, expire_callback_tasks(state), opts) do
      {:ok, next_state} ->
        {:reply, {:ok, next_state}, next_state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:request, method, params, normalizer, opts},
        from,
        %{lifecycle: %{lifecycle_state: :recovering}} = state
      ) do
    FastestMCP.Client.HTTP.enqueue_recovery_operation(
      state,
      {:request, from, method, params, normalizer, opts}
    )
  end

  def handle_call({:request, method, params, normalizer, opts}, from, state) do
    case start_outbound_request(state, method, params, normalizer, opts, {:sync, from}) do
      {:ok, _ref, _request_id, _task_augmented, next_state} -> {:noreply, next_state}
      {:cached, result, next_state} -> {:reply, {:ok, result}, next_state}
      {:error, exception, next_state} -> {:reply, {:error, exception}, next_state}
    end
  end

  def handle_call(
        {:request_async, method, params, normalizer, opts, owner},
        from,
        %{lifecycle: %{lifecycle_state: :recovering}} = state
      ) do
    FastestMCP.Client.HTTP.enqueue_recovery_operation(
      state,
      {:request_async, from, owner, method, params, normalizer, opts}
    )
  end

  def handle_call({:request_async, method, params, normalizer, opts, owner}, _from, state) do
    case start_outbound_request(state, method, params, normalizer, opts, {:async, owner}) do
      {:ok, ref, request_id, task_augmented, next_state} ->
        {:reply, {:ok, ref, request_id, task_augmented}, next_state}

      {:error, exception, next_state} ->
        {:reply, {:error, exception}, next_state}
    end
  end

  def handle_call({:cancel_request, ref, reason}, _from, state) do
    case cancel_outbound_request(state, ref, reason) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:cancel_ready_waiter, token}, state) do
    {:noreply, drop_ready_waiter(state, token)}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:http_request_started, ref, worker_pid, request_ref}, state) do
    case Map.get(state.pending.in_flight, ref) do
      %{worker_pid: ^worker_pid, request_ref: nil} ->
        {:noreply, put_in(state.pending.in_flight[ref].request_ref, request_ref)}

      %{worker_pid: ^worker_pid, request_ref: ^request_ref} ->
        {:noreply, state}

      %{worker_pid: ^worker_pid, request_ref: previous_request_ref} ->
        FastestMCP.Client.HTTP.cancel_http_request(previous_request_ref)
        {:noreply, put_in(state.pending.in_flight[ref].request_ref, request_ref)}

      _stale_or_unknown_request ->
        FastestMCP.Client.HTTP.cancel_http_request(request_ref)
        {:noreply, state}
    end
  end

  def handle_info(
        {:http_request_complete, ref,
         {:missing_session, %Error{} = error, stale_session_id, generation}},
        state
      ) do
    case pop_completed_http_entry(state, ref) do
      {:error, state} ->
        {:noreply, state}

      {:ok, entry, state} ->
        if generation == state.lifecycle.session_generation and
             stale_session_id == state.session_id do
          {:noreply, begin_session_recovery(state, entry, error)}
        else
          FastestMCP.Client.RequestOwnership.reply_request_entry(
            entry,
            {:error, FastestMCP.Client.HTTP.original_request_not_replayed(error)}
          )

          {:noreply, state}
        end
    end
  end

  def handle_info(
        {:http_request_complete, ref,
         {:modern_subscription_terminated, %Error{} = error, retry_delay}},
        state
      ) do
    case Map.get(state.pending.in_flight, ref) do
      %{
        method: "subscriptions/listen",
        protocol_version: "2026-07-28"
      } = entry ->
        {:noreply, schedule_modern_subscription_reconnect(state, ref, entry, error, retry_delay)}

      _stale_or_cancelled_request ->
        {:noreply, state}
    end
  end

  def handle_info({:session_recovery_complete, generation, result}, state) do
    {:noreply, finish_session_recovery(state, generation, result)}
  end

  def handle_info(
        {:stale_session_detected, %Error{} = error, stale_session_id, generation},
        state
      ) do
    if state.lifecycle.lifecycle_state == :initialized and
         generation == state.lifecycle.session_generation and
         stale_session_id == state.session_id do
      {:noreply, begin_session_recovery(state, nil, error)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:http_request_complete, ref, result}, state) do
    {:noreply, complete_http_request(state, ref, result)}
  end

  def handle_info({:reconnect_modern_subscription, ref, reconnect_token}, state) do
    case Map.get(state.pending.in_flight, ref) do
      %{
        method: "subscriptions/listen",
        protocol_version: "2026-07-28",
        reconnect_token: ^reconnect_token,
        worker_pid: nil,
        worker_ref: nil,
        request_ref: nil
      } = entry ->
        {:noreply, reopen_modern_subscription(state, ref, entry)}

      _stale_active_or_cancelled_request ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, ref}, state) do
    case Map.pop(state.pending.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {entry, in_flight} when is_map(entry) ->
        %{method: method, timeout_ms: timeout_ms} = entry
        worker_pid = Map.get(entry, :worker_pid)
        worker_ref = Map.get(entry, :worker_ref)

        maybe_send_outbound_cancellation(state, entry, "request timed out")
        FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))
        FastestMCP.Client.HTTP.cancel_http_request(Map.get(entry, :request_ref))

        if is_pid(worker_pid) do
          Process.exit(worker_pid, :kill)
        end

        if worker_ref do
          Process.demonitor(worker_ref, [:flush])
        end

        FastestMCP.Client.RequestOwnership.reply_request_entry(
          entry,
          {:error,
           %Error{
             code: :timeout,
             message: "#{method} timed out",
             details: %{timeout_ms: timeout_ms}
           }}
        )

        {:noreply,
         %{
           state
           | pending: %{
               state.pending
               | in_flight: in_flight,
                 worker_refs:
                   FastestMCP.Client.RequestOwnership.drop_worker_ref(
                     state.pending.worker_refs,
                     worker_ref
                   ),
                 request_owner_refs:
                   FastestMCP.Client.RequestOwnership.drop_owner_ref(
                     state.pending.request_owner_refs,
                     entry.owner_ref
                   )
             },
             stdio: %{
               state.stdio
               | pending_stdio_ref:
                   if(state.stdio.pending_stdio_ref == ref) do
                     nil
                   else
                     state.stdio.pending_stdio_ref
                   end,
                 pending_stdio_refs: Map.delete(state.stdio.pending_stdio_refs, entry.request_id)
             }
         }}
    end
  end

  def handle_info(:callback_request_id_capacity_exhausted, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, worker_ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.lifecycle.readiness_owner_refs, worker_ref) ->
        token = Map.fetch!(state.lifecycle.readiness_owner_refs, worker_ref)
        {:noreply, drop_ready_waiter(state, token, false)}

      match?(%{owner_ref: ^worker_ref}, state.lifecycle.discovery_attempt) ->
        attempt = state.lifecycle.discovery_attempt

        {:noreply,
         %{
           state
           | discovery_result: attempt.previous_discovery_result,
             selected_protocol_version: attempt.previous_protocol_version,
             session_id: attempt.previous_session_id,
             server_identity: attempt.previous_server_identity,
             lifecycle: %{
               state.lifecycle
               | lifecycle_state: attempt.previous_lifecycle,
                 discovery_attempt: nil
             }
         }}

      state.lifecycle.initialization_owner_ref == worker_ref ->
        next_state =
          %{
            state
            | initialize_result: nil,
              advertised_client_capabilities: nil,
              lifecycle: %{
                state.lifecycle
                | lifecycle_state: :failed,
                  initialization_owner_ref: nil
              }
          }

        {:noreply, fail_ready_waiters(next_state, readiness_error(next_state))}

      match?(%{monitor_ref: ^worker_ref}, state.lifecycle.recovery) ->
        error = %Error{
          code: :internal_error,
          message: "HTTP MCP session recovery worker exited",
          details: %{reason: inspect(reason)}
        }

        {:noreply,
         finish_session_recovery(state, state.lifecycle.recovery.generation, {:error, error})}

      match?(%{monitor_ref: ^worker_ref}, state.catalog.tool_catalog_load) ->
        error = %Error{
          code: :internal_error,
          message: "tool catalog loader exited",
          details: %{reason: inspect(reason)}
        }

        Enum.each(state.catalog.tool_catalog_load.waiters, &GenServer.reply(&1, {:error, error}))
        {:noreply, %{state | catalog: %{state.catalog | tool_catalog_load: nil}}}

      match?(%{monitor_ref: ^worker_ref}, state.session_stream) ->
        {:noreply, handle_session_stream_down(state, reason)}

      Map.has_key?(state.callbacks.callback_task_refs, worker_ref) ->
        {:noreply, handle_callback_task_down(state, worker_ref, reason)}

      Map.has_key?(state.callbacks.callback_worker_refs, worker_ref) ->
        {:noreply, handle_callback_worker_down(state, worker_ref, reason)}

      Map.has_key?(state.pending.request_owner_refs, worker_ref) ->
        {:noreply, cancel_request_for_dead_owner(state, worker_ref)}

      true ->
        case Map.pop(state.pending.worker_refs, worker_ref) do
          {nil, _worker_refs} ->
            {:noreply, state}

          {ref, worker_refs} ->
            case Map.pop(state.pending.in_flight, ref) do
              {nil, _in_flight} ->
                {:noreply, %{state | pending: %{state.pending | worker_refs: worker_refs}}}

              {%{timer_ref: timer_ref} = entry, in_flight} ->
                FastestMCP.Client.RequestOwnership.cancel_timer(timer_ref)

                FastestMCP.Client.HTTP.cancel_http_request(
                  get_in(state.pending.in_flight, [ref, :request_ref])
                )

                error =
                  %Error{
                    code: :internal_error,
                    message: "client request worker crashed",
                    details: %{reason: inspect(reason)}
                  }

                FastestMCP.Client.RequestOwnership.reply_request_entry(entry, {:error, error})

                {:noreply,
                 %{
                   state
                   | pending: %{
                       state.pending
                       | in_flight: in_flight,
                         worker_refs: worker_refs,
                         request_owner_refs:
                           FastestMCP.Client.RequestOwnership.drop_owner_ref(
                             state.pending.request_owner_refs,
                             entry.owner_ref
                           )
                     }
                 }}
            end
        end
    end
  end

  def handle_info({:session_stream_request_started, stream_ref, worker_pid, request_ref}, state) do
    case state.session_stream do
      %{stream_ref: ^stream_ref, pid: ^worker_pid} = session_stream ->
        case Map.get(session_stream, :request_ref) do
          nil ->
            {:noreply, put_in(state.session_stream.request_ref, request_ref)}

          ^request_ref ->
            {:noreply, state}

          previous_request_ref ->
            FastestMCP.Client.HTTP.cancel_http_request(previous_request_ref)
            {:noreply, put_in(state.session_stream.request_ref, request_ref)}
        end

      _stale_or_unknown_stream ->
        FastestMCP.Client.HTTP.cancel_http_request(request_ref)
        {:noreply, state}
    end
  end

  def handle_info({:session_stream_opened, stream_ref}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      state =
        state
        |> put_in([Access.key(:session_stream), :started?], true)
        |> put_in([Access.key(:session_stream), :waiters], [])
        |> reply_session_stream_waiters(:ok, Map.get(state.session_stream, :waiters, []))

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_stream_failed, stream_ref, %Error{} = error}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      session_stream = state.session_stream

      FastestMCP.Client.HTTP.cancel_http_request(session_stream.request_ref)

      if session_stream.monitor_ref do
        Process.demonitor(session_stream.monitor_ref, [:flush])
      end

      state =
        reply_session_stream_waiters(
          %{state | session_stream: nil},
          {:error, error},
          Map.get(session_stream, :waiters, [])
        )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_stream_event, stream_ref, event}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      case FastestMCP.Client.HTTP.classify_stream_message(event) do
        {:server_request, message} ->
          case handle_server_request(message, state, []) do
            {:ok, next_state} -> {:noreply, next_state}
            {:error, _error} -> {:noreply, state}
          end

        {:notification, message} ->
          {:noreply, route_server_notification(message, state)}

        {:error, %Error{} = error, message} ->
          if is_map(message) and not is_nil(message["id"]) and is_binary(message["method"]) do
            post_client_response_async(
              state,
              message["id"],
              {:error, error},
              callback_method: message["method"]
            )
          end

          {:noreply, state}

        :ignore ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:server_notification, message}, state) do
    {:noreply, route_server_notification(message, state)}
  end

  def handle_info({:task_wait_timeout, task_id, waiter_ref}, state) do
    case get_in(state.tasks.task_registry, [task_id, :waiters, waiter_ref]) do
      %{from: from, timer_ref: timer_ref} ->
        FastestMCP.Client.RequestOwnership.cancel_timer(timer_ref)
        GenServer.reply(from, :timeout)

        {:noreply,
         update_in(state.tasks.task_registry[task_id][:waiters], &Map.delete(&1, waiter_ref))}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:callback_request_complete, request_id, result}, state) do
    case Map.pop(state.callbacks.callback_requests, request_id) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        Process.demonitor(request.monitor_ref, [:flush])

        next_state =
          %{
            state
            | callbacks: %{
                state.callbacks
                | callback_requests: requests,
                  callback_worker_refs:
                    Map.delete(state.callbacks.callback_worker_refs, request.monitor_ref)
              }
          }
          |> maybe_track_url_elicitation(request, result)

        post_client_response_async(next_state, request_id, result, request.opts)
        {:noreply, next_state}
    end
  end

  def handle_info({:callback_task_complete, task_id, {:ok, result}}, state) do
    {:noreply, complete_callback_task(state, task_id, :completed, result, nil)}
  end

  def handle_info({:callback_task_complete, task_id, {:error, %Error{} = error}}, state) do
    {:noreply, complete_callback_task(state, task_id, :failed, nil, error)}
  end

  def handle_info({port, {:data, data}}, %{transport: %{type: :stdio, port: port}} = state) do
    FastestMCP.Client.HTTP.handle_connected_transport_data(state, data)
  end

  def handle_info(
        {:fastest_mcp_transport_data, coordinator, data},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      )
      when is_binary(data) do
    FastestMCP.Client.HTTP.handle_connected_transport_data(state, data)
  end

  def handle_info(
        {port, {:exit_status, status}},
        %{transport: %{type: :stdio, port: port}} = state
      ) do
    error =
      %Error{
        code: :internal_error,
        message: "stdio client transport exited",
        details: %{status: status}
      }

    case retire_stdio_transport(state) do
      {:ok, retired_state} ->
        if restartable_modern_stdio?(retired_state) do
          {:noreply, begin_stdio_restart(retired_state, error)}
        else
          {:stop, :normal, fail_connected_transport_requests(retired_state, error)}
        end

      {:error, reason, retained_state} ->
        cleanup_error = %Error{
          code: :internal_error,
          message: "stdio process cleanup could not prove termination",
          details: %{status: status, reason: inspect(reason)}
        }

        retained_state = %{
          retained_state
          | lifecycle: %{
              retained_state.lifecycle
              | lifecycle_state: :failed,
                disconnecting?: true
            }
        }

        {:noreply, fail_connected_transport_requests(retained_state, cleanup_error)}
    end
  end

  def handle_info(
        {:fastest_mcp_transport_closed, coordinator, reason},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      ) do
    error = %Error{
      code: :internal_error,
      message: "in-process client transport closed",
      details: %{reason: inspect(reason)}
    }

    {:stop, :normal, fail_connected_transport_requests(state, error)}
  end

  def handle_info(
        {:restart_stdio_transport, token},
        %{stdio: %{stdio_restart_token: token}} = state
      ) do
    case ClientTransport.open(state.transport, self(), auth_input: state.auth_input) do
      {:ok, transport} ->
        state =
          state
          |> Map.put(:transport, transport)
          |> put_in([Access.key(:stdio), Access.key(:stdio_restart_timer_ref)], nil)
          |> put_in([Access.key(:stdio), Access.key(:stdio_restart_token)], nil)
          |> reopen_modern_stdio_subscriptions()
          |> release_ready_waiters()

        {:noreply, state}

      {:error, reason} ->
        error = %Error{
          code: :internal_error,
          message: "failed to restart stdio client transport",
          details: %{reason: inspect(reason), attempt: state.stdio.stdio_restart_attempt}
        }

        case schedule_stdio_restart(state, error) do
          {:ok, next_state} -> {:noreply, next_state}
          {:error, next_state} -> {:stop, :normal, next_state}
        end
    end
  end

  def handle_info({:restart_stdio_transport, _stale_token}, state) do
    {:noreply, state}
  end

  def handle_info(:oauth_credentials_refreshed, state) do
    {:noreply, rotate_auth_partition(state)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp complete_http_request(state, ref, result) do
    case Map.pop(state.pending.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {%{timer_ref: timer_ref, worker_ref: worker_ref, normalizer: normalizer} = entry, in_flight} ->
        FastestMCP.Client.RequestOwnership.cancel_timer(timer_ref)
        FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))

        FastestMCP.Client.HTTP.cancel_http_request(
          get_in(state.pending.in_flight, [ref, :request_ref])
        )

        if worker_ref do
          Process.demonitor(worker_ref, [:flush])
        end

        {reply, state, cache_hint} =
          apply_http_response_metadata(result, state, entry)

        state = maybe_store_response_cache(state, entry, reply, cache_hint)
        state = retain_task_progress(state, entry, reply)
        FastestMCP.Client.RequestOwnership.reply_request_entry(entry, reply)

        %{
          state
          | initialize_result:
              FastestMCP.Client.Codec.initialize_result_for(
                normalizer,
                reply,
                state.initialize_result
              ),
            pending: %{
              state.pending
              | in_flight: in_flight,
                worker_refs:
                  FastestMCP.Client.RequestOwnership.drop_worker_ref(
                    state.pending.worker_refs,
                    worker_ref
                  ),
                request_owner_refs:
                  FastestMCP.Client.RequestOwnership.drop_owner_ref(
                    state.pending.request_owner_refs,
                    entry.owner_ref
                  )
            }
        }
    end
  end

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    FastestMCP.Client.RequestOwnership.cancel_timer(state.stdio.stdio_restart_timer_ref)

    if session_stream = state.session_stream do
      FastestMCP.Client.HTTP.cancel_http_request(session_stream.request_ref)

      if is_pid(session_stream.pid) do
        Process.exit(session_stream.pid, :kill)
      end

      if session_stream.monitor_ref do
        Process.demonitor(session_stream.monitor_ref, [:flush])
      end
    end

    Enum.each(state.pending.in_flight, fn {_ref, entry} ->
      maybe_send_outbound_cancellation(state, entry, "client disconnected")
      FastestMCP.Client.HTTP.cancel_http_request(Map.get(entry, :request_ref))

      if is_pid(entry[:worker_pid]) do
        Process.exit(entry.worker_pid, :kill)
      end

      if entry[:worker_ref] do
        Process.demonitor(entry.worker_ref, [:flush])
      end

      FastestMCP.Client.RequestOwnership.cancel_timer(entry[:timer_ref])
      FastestMCP.Client.RequestOwnership.cancel_timer(entry[:reconnect_timer_ref])

      FastestMCP.Client.RequestOwnership.finish_async_request_trace(
        entry,
        {:error, client_not_running_error()}
      )
    end)

    if is_pid(state.worker_supervisor) and Process.alive?(state.worker_supervisor) do
      Supervisor.stop(state.worker_supervisor, :normal)
    end

    if match?(%{pid: pid} when is_pid(pid), state.oauth) and Process.alive?(state.oauth.pid) do
      GenServer.stop(state.oauth.pid, :normal)
    end

    terminate_remote_http_session(state)

    ClientTransport.close(state.transport)

    :ok
  end

  defp terminate_remote_http_session(
         %{
           transport: %{type: :streamable_http, base_url: base_url},
           session_id: session_id
         } = state
       )
       when is_binary(session_id) and session_id != "" do
    _ =
      HTTPClientTransport.request(:delete, base_url,
        headers:
          FastestMCP.Client.HTTP.transport_headers(
            [{"accept", "application/json"}, {"connection", "close"}],
            state,
            []
          ),
        timeout_ms: min(state.timeout_ms, 1000)
      )

    :ok
  end

  defp terminate_remote_http_session(_state) do
    :ok
  end

  def fail_initialize(%Client{pid: pid}, reason) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:fail_initialize, reason})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def fail_discover(%Client{pid: pid}, token, reason) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:fail_discover, token, reason})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp resolve_client(%Client{pid: pid} = client) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, client}
    else
      :error
    end
  end

  defp resolve_client(client_ref) do
    case GenServer.whereis(client_ref) do
      pid when is_pid(pid) -> {:ok, %Client{pid: pid}}
      nil -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def pin_client!(client_ref) do
    case resolve_client(client_ref) do
      {:ok, client} ->
        client

      :error ->
        raise Error, code: :internal_error, message: "MCP client is not running"
    end
  end

  defp do_await_ready(client_ref, deadline, follow_name?) do
    case resolve_client(client_ref) do
      {:ok, client} -> await_resolved_client(client_ref, client, deadline, follow_name?)
      :error when follow_name? -> retry_named_ready(client_ref, deadline)
      :error -> raise client_not_running_error()
    end
  end

  defp await_resolved_client(original_ref, %Client{pid: pid}, deadline, follow_name?) do
    token = make_ref()
    monitor_ref = Process.monitor(pid)

    reply =
      try do
        GenServer.call(pid, {:await_ready, self(), token}, readiness_call_timeout(deadline))
      catch
        :exit, _reason -> :client_down
      end

    case reply do
      :ready ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:error, %Error{} = error} ->
        Process.demonitor(monitor_ref, [:flush])
        raise error

      :waiting ->
        receive do
          {Client, :ready, ^pid, ^token} ->
            Process.demonitor(monitor_ref, [:flush])
            :ok

          {Client, :ready_error, ^pid, ^token, %Error{} = error} ->
            Process.demonitor(monitor_ref, [:flush])
            raise error

          {:DOWN, ^monitor_ref, :process, ^pid, _reason} when follow_name? ->
            do_await_ready(original_ref, deadline, true)

          {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
            raise client_not_running_error()
        after
          readiness_remaining(deadline) ->
            GenServer.cast(pid, {:cancel_ready_waiter, token})
            Process.demonitor(monitor_ref, [:flush])
            raise readiness_timeout_error(deadline)
        end

      :client_down when follow_name? ->
        Process.demonitor(monitor_ref, [:flush])
        do_await_ready(original_ref, deadline, true)

      :client_down ->
        Process.demonitor(monitor_ref, [:flush])
        raise client_not_running_error()
    end
  end

  defp retry_named_ready(client_ref, deadline) do
    remaining = readiness_remaining(deadline)

    if remaining == 0 do
      raise readiness_timeout_error(deadline)
    else
      Process.sleep(
        if(remaining == :infinity) do
          25
        else
          min(remaining, 25)
        end
      )

      do_await_ready(client_ref, deadline, true)
    end
  end

  defp readiness_call_timeout(:infinity) do
    :infinity
  end

  defp readiness_call_timeout(deadline) do
    max(readiness_remaining(deadline), 1) + 1000
  end

  defp readiness_remaining(:infinity) do
    :infinity
  end

  defp readiness_remaining(deadline) do
    max(deadline - monotonic_ms(), 0)
  end

  defp readiness_timeout_error(:infinity) do
    %Error{code: :timeout, message: "MCP client did not become ready"}
  end

  defp readiness_timeout_error(_deadline) do
    %Error{code: :timeout, message: "MCP client did not become ready before the deadline"}
  end

  defp client_not_running_error do
    %Error{code: :internal_error, message: "MCP client is not running"}
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp client_ready?(state) do
    state.lifecycle.lifecycle_state == :initialized and is_nil(state.lifecycle.recovery) and
      is_nil(state.stdio.stdio_restart_token) and ClientTransport.connected?(state.transport)
  rescue
    _error -> false
  end

  defp readiness_error(state) do
    %Error{
      code: :internal_error,
      message: "MCP client failed to become ready",
      details: %{lifecycle_state: state.lifecycle.lifecycle_state}
    }
  end

  defp release_ready_waiters(state) do
    if client_ready?(state) do
      Enum.each(state.lifecycle.readiness_waiters, fn {token, waiter} ->
        send(waiter.owner, {Client, :ready, self(), token})
        Process.demonitor(waiter.owner_ref, [:flush])
      end)

      %{state | lifecycle: %{state.lifecycle | readiness_waiters: %{}, readiness_owner_refs: %{}}}
    else
      state
    end
  end

  defp fail_ready_waiters(state, %Error{} = error) do
    Enum.each(state.lifecycle.readiness_waiters, fn {token, waiter} ->
      send(waiter.owner, {Client, :ready_error, self(), token, error})
      Process.demonitor(waiter.owner_ref, [:flush])
    end)

    %{state | lifecycle: %{state.lifecycle | readiness_waiters: %{}, readiness_owner_refs: %{}}}
  end

  defp drop_ready_waiter(state, token, demonitor? \\ true) do
    case Map.pop(state.lifecycle.readiness_waiters, token) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        if demonitor? do
          Process.demonitor(waiter.owner_ref, [:flush])
        end

        %{
          state
          | lifecycle: %{
              state.lifecycle
              | readiness_waiters: waiters,
                readiness_owner_refs:
                  Map.delete(state.lifecycle.readiness_owner_refs, waiter.owner_ref)
            }
        }
    end
  end

  defp negotiate_ready(%Client{} = client, opts) do
    timeout_opts = [timeout_ms: Keyword.get(opts, :init_timeout_ms, @default_init_timeout_ms)]

    case Keyword.get(opts, :protocol_version, :auto) do
      "2025-11-25" ->
        FastestMCP.Client.Requests.initialize(client, %{}, timeout_opts)

      "2026-07-28" ->
        FastestMCP.Client.Requests.discover(client, timeout_opts)

      :auto ->
        try do
          FastestMCP.Client.Requests.discover(client, timeout_opts)
        rescue
          error in [Error, ProtocolError] ->
            if legacy_fallback_evidence?(error, client_transport_type(client)) do
              FastestMCP.Client.Requests.initialize(client, %{}, timeout_opts)
            else
              reraise error, __STACKTRACE__
            end
        end
    end
  end

  defp legacy_fallback_evidence?(%ProtocolError{method: "server/discover"}, :stdio) do
    true
  end

  defp legacy_fallback_evidence?(%ProtocolError{}, :streamable_http) do
    false
  end

  defp legacy_fallback_evidence?(%Error{} = error, :stdio) do
    not recognized_modern_discovery_error?(error)
  end

  defp legacy_fallback_evidence?(%Error{} = error, :streamable_http) do
    details =
      if is_map(error.details) do
        error.details
      else
        %{}
      end

    status = Map.get(details, :status, Map.get(details, "status"))
    jsonrpc_code = Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))

    not recognized_modern_discovery_error?(error) and
      (jsonrpc_code == -32601 or
         (status == 400 and (is_nil(jsonrpc_code) or is_integer(jsonrpc_code))) or
         (status in [404, 405] and is_nil(jsonrpc_code)))
  end

  defp legacy_fallback_evidence?(_error, _transport) do
    false
  end

  defp recognized_modern_discovery_error?(%Error{code: code, details: details}) do
    details =
      if is_map(details) do
        details
      else
        %{}
      end

    jsonrpc_code = Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))

    code in [:header_mismatch, :missing_required_client_capability, :unsupported_protocol_version] or
      jsonrpc_code in [-32020, -32021, -32022]
  end

  def client_transport_type(%Client{pid: pid}) do
    GenServer.call(pid, :transport_type)
  end

  defp validate_outbound_request_lifecycle(
         %{lifecycle: %{lifecycle_state: :initializing}},
         "initialize",
         :initialize
       ) do
    :ok
  end

  defp validate_outbound_request_lifecycle(
         %{lifecycle: %{lifecycle_state: state}},
         "server/discover",
         _normalizer
       )
       when state in [:new, :discovering, :initialized] do
    :ok
  end

  defp validate_outbound_request_lifecycle(
         %{lifecycle: %{lifecycle_state: :initializing}},
         "ping",
         _normalizer
       ) do
    :ok
  end

  defp validate_outbound_request_lifecycle(
         %{lifecycle: %{lifecycle_state: :initialized}},
         method,
         _normalizer
       )
       when method != "initialize" do
    :ok
  end

  defp validate_outbound_request_lifecycle(state, method, _normalizer) do
    action =
      if method == "initialize" do
        "initialize"
      else
        "send #{method}"
      end

    {:error, lifecycle_error(state, action)}
  end

  def validate_outbound_notification_lifecycle(
        %{lifecycle: %{lifecycle_state: :initializing}},
        "notifications/initialized"
      ) do
    :ok
  end

  def validate_outbound_notification_lifecycle(
        %{lifecycle: %{lifecycle_state: :initialized}},
        method
      )
      when method != "notifications/initialized" do
    :ok
  end

  def validate_outbound_notification_lifecycle(state, method) do
    {:error, lifecycle_error(state, "send #{method}")}
  end

  defp lifecycle_error(state, action) do
    %Error{
      code: :invalid_request,
      message: "cannot #{action} while client is #{state.lifecycle.lifecycle_state}",
      details: %{lifecycle_state: state.lifecycle.lifecycle_state}
    }
  end

  defp demonitor_initialization_owner(nil) do
    :ok
  end

  defp demonitor_initialization_owner(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp normalize_transport({:stdio, command}, opts) do
    normalize_transport({:stdio, command, []}, opts)
  end

  defp normalize_transport({:stdio, command, args}, opts)
       when is_binary(command) and is_list(args) do
    with {:ok, env} <- normalize_stdio_env_option(Keyword.fetch(opts, :env)),
         {:ok, process_group} <-
           normalize_stdio_process_group(Keyword.get(opts, :stdio_process_group)) do
      {:ok,
       %{
         type: :stdio,
         adapter: StdioClientTransport,
         command: command,
         args: Enum.map(args, &to_string/1),
         env: env,
         process_group: process_group,
         stdio_process: nil,
         generation: 0,
         port: nil,
         session_id: nil
       }}
    end
  end

  defp normalize_transport({:in_process, server_name}, opts)
       when is_binary(server_name) or is_atom(server_name) do
    server_name = to_string(server_name)

    with :ok <- validate_in_process_options(opts),
         :ok <- ensure_in_process_server_running(server_name) do
      connection_id = make_ref()

      {:ok,
       %{
         type: :in_process,
         adapter: InProcessClientTransport,
         server_name: server_name,
         connection_id: connection_id,
         session_id: nil,
         coordinator: nil,
         supervisor: nil
       }}
    end
  end

  defp normalize_transport(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      Keyword.has_key?(opts, :session_id) ->
        {:error,
         %Error{
           code: :bad_request,
           message: "client session_id is server-negotiated and cannot be configured"
         }}

      uri.scheme in ["http", "https"] ->
        endpoint =
          uri
          |> FastestMCP.Client.Codec.ensure_http_path()
          |> URI.to_string()

        {:ok,
         %{
           type: :streamable_http,
           adapter: HTTPClientTransport,
           base_url: endpoint,
           session_id: nil
         }}

      true ->
        {:error,
         %Error{
           code: :bad_request,
           message: "unsupported client target",
           details: %{target: url}
         }}
    end
  end

  defp normalize_transport(other, _opts) do
    {:error,
     %Error{
       code: :bad_request,
       message: "unsupported client target",
       details: %{target: inspect(other)}
     }}
  end

  defp ensure_in_process_server_running(server_name) do
    case FastestMCP.Registry.lookup_server(server_name) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, :not_found} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "in-process server is not running",
           details: %{server_name: server_name}
         }}
    end
  end

  defp validate_in_process_options(opts) do
    unsupported =
      [
        :oauth,
        :headers,
        :authorization,
        :access_token,
        :session_id,
        :session_stream,
        :sse_reconnect,
        :max_sse_event_bytes,
        :env,
        :legacy_stdio_auth_metadata,
        :stdio_restart,
        :stdio_process_group
      ]
      |> Enum.filter(&Keyword.has_key?(opts, &1))

    if unsupported == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_params,
         message: "in-process transport does not accept HTTP, SSE, or stdio process options",
         details: %{unsupported_options: unsupported}
       }}
    end
  end

  defp normalize_stdio_env_option(:error) do
    {:ok, :inherit}
  end

  defp normalize_stdio_env_option({:ok, env}) do
    normalize_stdio_env(env)
  end

  defp normalize_stdio_process_group(nil) do
    {:ok, nil}
  end

  defp normalize_stdio_process_group(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:launcher, :launcher_args]
      unsupported = Keyword.keys(opts) -- allowed

      with [] <- unsupported,
           launcher when is_binary(launcher) <- Keyword.get(opts, :launcher),
           true <- Path.type(launcher) == :absolute and not String.contains?(launcher, <<0>>),
           launcher_args when is_list(launcher_args) <- Keyword.get(opts, :launcher_args, []),
           true <- length(launcher_args) <= 64,
           {:ok, launcher_args} <- normalize_stdio_launcher_args(launcher_args),
           true <-
             Enum.reduce(launcher_args, byte_size(launcher), &(byte_size(&1) + &2)) <= 16384 do
        {:ok, %{launcher: launcher, launcher_args: launcher_args}}
      else
        _other -> invalid_stdio_process_group()
      end
    else
      invalid_stdio_process_group()
    end
  end

  defp normalize_stdio_process_group(_opts) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio_process_group must be a keyword list"
     }}
  end

  defp invalid_stdio_process_group do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio_process_group requires an absolute launcher and bounded launcher_args"
     }}
  end

  defp normalize_stdio_launcher_args(args) do
    Enum.reduce_while(args, {:ok, []}, fn
      value, {:ok, values} when is_binary(value) or is_atom(value) or is_integer(value) ->
        value = to_string(value)

        if byte_size(value) <= 4096 and not String.contains?(value, <<0>>) do
          {:cont, {:ok, [value | values]}}
        else
          {:halt, :error}
        end

      _value, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_stdio_env(env) when is_map(env) do
    env |> Map.to_list() |> normalize_stdio_env()
  end

  defp normalize_stdio_env(env) when is_list(env) do
    normalized =
      Enum.map(env, fn
        {name, value}
        when (is_binary(name) or is_atom(name)) and
               (is_binary(value) or is_integer(value) or
                  (is_atom(value) and value not in [false, nil])) ->
          {to_string(name), to_string(value)}

        _other ->
          :invalid
      end)

    cond do
      :invalid in normalized ->
        invalid_stdio_env()

      duplicate_stdio_env_names?(normalized) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "stdio env contains duplicate variable names"
         }}

      not Enum.all?(normalized, &valid_stdio_env_entry?/1) ->
        invalid_stdio_env()

      stdio_env_bounds_exceeded?(normalized) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "stdio env exceeds the bounded environment size"
         }}

      true ->
        {:ok, {:replace, Enum.sort_by(normalized, &elem(&1, 0))}}
    end
  end

  defp normalize_stdio_env(_env) do
    invalid_stdio_env()
  end

  defp invalid_stdio_env do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio env must be a map or keyword list of scalar values"
     }}
  end

  defp valid_stdio_env_entry?({name, value}) do
    byte_size(name) in 1..128 and
      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and
      not String.contains?(value, <<0>>)
  end

  defp stdio_env_bounds_exceeded?(entries) do
    length(entries) > 512 or
      Enum.any?(entries, fn {_name, value} -> byte_size(value) > 16384 end) or
      environment_bytes(entries) > 65536
  end

  defp environment_bytes(entries) do
    Enum.reduce(entries, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 2
    end)
  end

  defp duplicate_stdio_env_names?(entries) do
    names = Enum.map(entries, &elem(&1, 0))
    length(names) != MapSet.size(MapSet.new(names))
  end

  defp open_client_transport(state) do
    case ClientTransport.open(state.transport, self(), auth_input: state.auth_input) do
      {:ok, transport} ->
        {:ok, %{state | transport: transport}}

      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop,
         %Error{
           code: :internal_error,
           message: "failed to open client transport",
           details: %{transport: state.transport.type, reason: inspect(reason)}
         }}
    end
  end

  defp restartable_modern_stdio?(state) do
    not state.lifecycle.disconnecting? and state.lifecycle.lifecycle_state == :initialized and
      state.selected_protocol_version == "2026-07-28" and
      state.stdio.stdio_restart.max_attempts > state.stdio.stdio_restart_attempt
  end

  defp retire_client_transport(%{transport: %{type: :stdio}} = state) do
    retire_stdio_transport(state)
  end

  defp retire_client_transport(state) do
    case ClientTransport.close(state.transport) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp begin_stdio_restart(state, error) do
    state
    |> invalidate_client_caches(:stdio_replacement)
    |> detach_stdio_requests_for_restart(error)
    |> schedule_stdio_restart(error)
    |> case do
      {:ok, next_state} -> next_state
      {:error, next_state} -> next_state
    end
  end

  defp retire_stdio_transport(%{transport: %{type: :stdio} = transport} = state) do
    retired_transport =
      transport
      |> Map.put(:port, nil)
      |> Map.put(:stdio_process, nil)

    case ClientTransport.close(transport) do
      :ok -> {:ok, %{state | transport: retired_transport}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp schedule_stdio_restart(state, error) do
    FastestMCP.Client.RequestOwnership.cancel_timer(state.stdio.stdio_restart_timer_ref)

    if state.stdio.stdio_restart_attempt < state.stdio.stdio_restart.max_attempts do
      attempt = state.stdio.stdio_restart_attempt + 1
      retry_ms = stdio_restart_delay(state.stdio.stdio_restart, attempt)
      token = make_ref()

      timer_ref =
        Process.send_after(self(), {:restart_stdio_transport, token}, retry_ms)

      {:ok,
       %{
         state
         | stdio: %{
             state.stdio
             | stdio_restart_attempt: attempt,
               stdio_restart_timer_ref: timer_ref,
               stdio_restart_token: token
           }
       }}
    else
      terminal_error = %{
        error
        | details:
            Map.merge(error.details, %{
              restart_attempts: state.stdio.stdio_restart_attempt,
              restart_exhausted: true
            })
      }

      {:error, fail_connected_transport_requests(state, terminal_error)}
    end
  end

  defp stdio_restart_delay(%{retry_ms: retry_ms, max_retry_ms: max_retry_ms}, attempt) do
    multiplier = Integer.pow(2, max(attempt - 1, 0))
    min(retry_ms * multiplier, max_retry_ms)
  end

  defp detach_stdio_requests_for_restart(state, error) do
    {subscriptions, ordinary_requests} =
      Enum.split_with(state.pending.in_flight, fn {_ref, entry} ->
        entry.method == "subscriptions/listen" and
          entry.protocol_version == "2026-07-28"
      end)

    Enum.each(ordinary_requests, fn {_ref, entry} ->
      FastestMCP.Client.RequestOwnership.cancel_timer(entry.timer_ref)
      FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))
      FastestMCP.Client.RequestOwnership.reply_request_entry(entry, {:error, error})

      if entry.owner_ref do
        Process.demonitor(entry.owner_ref, [:flush])
      end
    end)

    subscriptions =
      Map.new(subscriptions, fn {ref, entry} ->
        {ref,
         entry
         |> Map.put(:request_id, nil)
         |> Map.put(:subscription_acknowledged?, false)
         |> Map.put(:acknowledged_subscription_filter, nil)}
      end)

    subscription_owner_refs =
      subscriptions
      |> Map.values()
      |> Enum.map(& &1.owner_ref)
      |> MapSet.new()

    request_owner_refs =
      Map.filter(state.pending.request_owner_refs, fn {owner_ref, _ref} ->
        MapSet.member?(subscription_owner_refs, owner_ref)
      end)

    %{
      state
      | transport:
          state.transport
          |> Map.put(:port, nil)
          |> Map.put(:stdio_process, nil),
        pending: %{
          state.pending
          | in_flight: subscriptions,
            worker_refs: %{},
            request_owner_refs: request_owner_refs
        },
        stdio: %{
          state.stdio
          | pending_stdio_buffer: "",
            pending_stdio_ref: nil,
            pending_stdio_refs: %{},
            stdio_restart_timer_ref: nil,
            stdio_restart_token: nil
        }
    }
  end

  defp reopen_modern_stdio_subscriptions(state) do
    Enum.reduce(Map.keys(state.pending.in_flight), state, fn ref, next_state ->
      case Map.get(next_state.pending.in_flight, ref) do
        %{method: "subscriptions/listen", protocol_version: "2026-07-28"} = entry ->
          reopen_modern_stdio_subscription(next_state, ref, entry)

        _other ->
          next_state
      end
    end)
  end

  defp reopen_modern_stdio_subscription(state, ref, entry) do
    request_id = Integer.to_string(state.next_request_id)
    opts = Map.fetch!(entry, :request_opts)
    params = Map.fetch!(entry, :request_params)

    case safe_build_request("subscriptions/listen", params, request_id, state, opts) do
      {:ok, request} ->
        case safe_connected_transport_command(state.transport, request) do
          :ok ->
            entry =
              entry
              |> Map.put(:request_id, request_id)
              |> Map.put(:subscription_acknowledged?, false)
              |> Map.put(:acknowledged_subscription_filter, nil)

            state
            |> Map.put(:next_request_id, state.next_request_id + 1)
            |> put_in([Access.key(:pending), Access.key(:in_flight), ref], entry)
            |> put_in([Access.key(:stdio), Access.key(:pending_stdio_refs), request_id], ref)

          {:error, %Error{}} ->
            # The child may exit between Port.open/2 and the first command.
            # Keep the listener detached so the next bounded restart attempt
            # can re-establish it instead of failing the public handle early.
            state
        end

      {:error, %Error{} = error} ->
        fail_reopened_stdio_subscription(state, ref, entry, error)
    end
  end

  defp fail_reopened_stdio_subscription(state, ref, entry, error) do
    FastestMCP.Client.RequestOwnership.cancel_timer(entry.timer_ref)
    FastestMCP.Client.RequestOwnership.reply_request_entry(entry, {:error, error})

    %{
      state
      | pending: %{
          state.pending
          | in_flight: Map.delete(state.pending.in_flight, ref),
            request_owner_refs:
              FastestMCP.Client.RequestOwnership.drop_owner_ref(
                state.pending.request_owner_refs,
                entry.owner_ref
              )
        }
    }
  end

  def fail_connected_transport_requests(state, error) do
    Enum.each(state.pending.in_flight, fn {_ref, entry} ->
      FastestMCP.Client.RequestOwnership.cancel_timer(entry.timer_ref)
      FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))
      FastestMCP.Client.RequestOwnership.reply_request_entry(entry, {:error, error})

      if entry.owner_ref do
        Process.demonitor(entry.owner_ref, [:flush])
      end
    end)

    transport =
      case state.transport.type do
        # Preserve a live stdio handle until terminate/2 so fatal decoder or
        # protocol failures still shut down the complete process group.
        :stdio ->
          state.transport

        :in_process ->
          Map.put(state.transport, :coordinator, nil)
      end

    %{
      state
      | transport: transport,
        pending: %{state.pending | in_flight: %{}, worker_refs: %{}, request_owner_refs: %{}},
        stdio: %{
          state.stdio
          | pending_stdio_buffer: "",
            pending_stdio_ref: nil,
            pending_stdio_refs: %{},
            stdio_restart_timer_ref: nil,
            stdio_restart_token: nil
        }
    }
  end

  def safe_connected_transport_command(transport, message) do
    case ClientTransport.send_envelope(transport, message) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "#{connected_transport_name(transport.type)} client transport is closed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_oauth(state, nil) do
    {:ok, state}
  end

  defp maybe_start_oauth(%{transport: %{type: type}}, _oauth_opts)
       when type in [:stdio, :in_process] do
    {:error,
     %Error{
       code: :invalid_params,
       message: "oauth is supported only by the Streamable HTTP client transport"
     }}
  end

  defp maybe_start_oauth(state, oauth_opts) when is_list(oauth_opts) do
    with {:ok, max_auth_attempts} <-
           normalize_non_negative_integer(
             Keyword.get(oauth_opts, :max_auth_attempts, @default_max_auth_attempts),
             :max_auth_attempts
           ),
         oauth_opts <-
           oauth_opts
           |> Keyword.delete(:max_auth_attempts)
           |> Keyword.put(:credential_listener, self()),
         {:ok, pid} <- OAuth.start_link(oauth_opts) do
      {:ok,
       %{
         state
         | oauth: %{
             pid: pid,
             resource: state.transport.base_url,
             max_auth_attempts: max_auth_attempts
           }
       }}
    else
      {:error, %OAuthError{} = error} ->
        {:error, FastestMCP.Client.Codec.oauth_client_error(error)}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "failed to start OAuth client",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_oauth(_state, _oauth_opts) do
    {:error,
     %Error{code: :invalid_params, message: "oauth must be a keyword list when configured"}}
  end

  defp normalize_sse_reconnect!(false) do
    %{max_attempts: 0, min_retry_ms: 0, max_retry_ms: 0, default_retry_ms: 0}
  end

  defp normalize_sse_reconnect!(true) do
    normalize_sse_reconnect!([])
  end

  defp normalize_sse_reconnect!(opts) when is_list(opts) do
    max_attempts =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_attempts, @default_sse_max_reconnect_attempts),
        :max_attempts
      )

    min_retry_ms =
      normalize_non_negative_integer!(Keyword.get(opts, :min_retry_ms, 0), :min_retry_ms)

    max_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_retry_ms, @default_sse_max_retry_ms),
        :max_retry_ms
      )

    default_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :default_retry_ms, @default_sse_retry_ms),
        :default_retry_ms
      )

    if min_retry_ms > max_retry_ms or max_retry_ms > 60000 do
      raise Error,
        code: :invalid_params,
        message: "invalid SSE reconnect retry bounds",
        details: %{min_retry_ms: min_retry_ms, max_retry_ms: max_retry_ms}
    end

    %{
      max_attempts: max_attempts,
      min_retry_ms: min_retry_ms,
      max_retry_ms: max_retry_ms,
      default_retry_ms: default_retry_ms
    }
  end

  defp normalize_sse_reconnect!(_opts) do
    raise Error,
      code: :invalid_params,
      message: "sse_reconnect must be a keyword list, true, or false"
  end

  defp normalize_stdio_restart!(false) do
    %{max_attempts: 0, retry_ms: 0, max_retry_ms: 0}
  end

  defp normalize_stdio_restart!(true) do
    normalize_stdio_restart!([])
  end

  defp normalize_stdio_restart!(opts) when is_list(opts) do
    max_attempts =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_attempts, @default_stdio_restart_max_attempts),
        :max_attempts
      )

    retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :retry_ms, @default_stdio_restart_retry_ms),
        :retry_ms
      )

    max_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_retry_ms, @default_stdio_restart_max_retry_ms),
        :max_retry_ms
      )

    if retry_ms > max_retry_ms or max_retry_ms > 60000 do
      raise Error,
        code: :invalid_params,
        message: "invalid stdio restart retry bounds",
        details: %{retry_ms: retry_ms, max_retry_ms: max_retry_ms}
    end

    %{max_attempts: max_attempts, retry_ms: retry_ms, max_retry_ms: max_retry_ms}
  end

  defp normalize_stdio_restart!(_opts) do
    raise Error,
      code: :invalid_params,
      message: "stdio_restart must be a keyword list, true, or false"
  end

  defp normalize_non_negative_integer!(value, option) do
    case normalize_non_negative_integer(value, option) do
      {:ok, normalized} -> normalized
      {:error, %Error{} = error} -> raise error
    end
  end

  defp normalize_non_negative_integer(value, _option)
       when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp normalize_non_negative_integer(value, option) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "#{option} must be a non-negative integer",
       details: %{option: option, value: inspect(value)}
     }}
  end

  def normalize_positive_integer!(value, _option) when is_integer(value) and value > 0 do
    value
  end

  def normalize_positive_integer!(value, option) do
    raise ArgumentError, "#{option} must be a positive integer, got #{inspect(value)}"
  end

  defp request_timer(_ref, :infinity) do
    nil
  end

  defp request_timer(ref, timeout_ms) do
    Process.send_after(self(), {:request_timeout, ref}, timeout_ms)
  end

  def call_timeout(:infinity) do
    :infinity
  end

  def call_timeout(timeout_ms) do
    min(timeout_ms, @default_timeout_ms) + 1000
  end

  defp validate_transport_options(%{
         transport: %{type: type},
         protocol_preference: "2025-11-25",
         max_in_flight: max
       })
       when type in [:stdio, :in_process] and max != 1 do
    {:error,
     %Error{
       code: :bad_request,
       message: "legacy #{connected_transport_name(type)} max_in_flight must be 1",
       details: %{transport: type, max_in_flight: max, supported: 1}
     }}
  end

  defp validate_transport_options(%{transport: %{type: type}, max_in_flight: max})
       when type in [:stdio, :in_process] and
              (max == :infinity or (is_integer(max) and max > 0)) do
    :ok
  end

  defp validate_transport_options(%{transport: %{type: :streamable_http}}) do
    :ok
  end

  defp validate_transport_options(%{transport: %{type: type}, max_in_flight: max_in_flight})
       when type in [:stdio, :in_process] do
    {:error,
     %Error{
       code: :bad_request,
       message:
         "#{connected_transport_name(type)} max_in_flight must be a positive integer or :infinity",
       details: %{transport: type, max_in_flight: max_in_flight}
     }}
  end

  defp default_max_in_flight(type, "2025-11-25") when type in [:stdio, :in_process] do
    @default_stdio_max_in_flight
  end

  defp default_max_in_flight(type, _preference) when type in [:stdio, :in_process] do
    @default_modern_stdio_max_in_flight
  end

  defp default_max_in_flight(:streamable_http, _preference) do
    @default_http_max_in_flight
  end

  defp connected_transport_name(:stdio) do
    "stdio"
  end

  defp connected_transport_name(:in_process) do
    "in-process"
  end

  def validate_connected_transport_options(%{transport: %{type: :in_process}}, opts) do
    unsupported =
      [:authorization, :access_token, :headers, :oauth]
      |> Enum.filter(&Keyword.has_key?(opts, &1))

    if unsupported == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_params,
         message: "in-process requests accept auth_input, not HTTP authorization options",
         details: %{unsupported_options: unsupported}
       }}
    end
  end

  def validate_connected_transport_options(_state, _opts) do
    :ok
  end

  defp connected_transport_unavailable?(%{transport: %{type: type} = transport})
       when type in [:stdio, :in_process] do
    not ClientTransport.connected?(transport)
  end

  defp connected_transport_unavailable?(_state) do
    false
  end

  def session_stream_alive?(%{session_stream: %{pid: pid}}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def session_stream_alive?(_state) do
    false
  end

  def session_stream_started?(%{session_stream: %{pid: pid, started?: true}}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def session_stream_started?(_state) do
    false
  end

  defp handle_session_stream_down(%{session_stream: %{started?: true}} = state, _reason) do
    FastestMCP.Client.HTTP.cancel_http_request(state.session_stream.request_ref)
    %{state | session_stream: nil}
  end

  defp handle_session_stream_down(%{session_stream: session_stream} = state, reason) do
    FastestMCP.Client.HTTP.cancel_http_request(session_stream.request_ref)

    reply_session_stream_waiters(
      %{state | session_stream: nil},
      {:error,
       %Error{
         code: :internal_error,
         message: "session stream failed to open",
         details: %{reason: inspect(reason)}
       }},
      Map.get(session_stream, :waiters, [])
    )
  end

  defp reply_session_stream_waiters(state, _reply, []) do
    state
  end

  defp reply_session_stream_waiters(state, reply, waiters) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
    state
  end

  defp saturated?(%{max_in_flight: :infinity}) do
    false
  end

  defp saturated?(state) do
    map_size(state.pending.in_flight) >= state.max_in_flight
  end

  def start_outbound_request(state, method, params, normalizer, opts, reply_to) do
    params = maybe_put_scoped_progress_token(params, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, state.timeout_ms)

    timeout_ms =
      case Keyword.fetch(opts, :deadline) do
        {:ok, deadline} -> FastestMCP.Deadline.remaining(deadline)
        :error -> timeout_ms
      end

    protocol_version = FastestMCP.Client.Codec.selected_request_protocol_version(state, method)
    opts = Keyword.put(opts, :protocol_version, protocol_version)

    FastestMCP.Client.Trace.annotate_client_request_trace(opts, state, method, protocol_version)

    budget_validation = validate_request_budget(reply_to, opts)

    lifecycle_validation =
      validate_outbound_request_lifecycle(state, method, normalizer)

    transport_options_validation = validate_connected_transport_options(state, opts)

    normalizer =
      if method == "initialize" do
        {:initialize, "2025-11-25"}
      else
        normalizer
      end

    cond do
      match?({:error, %Error{}}, budget_validation) ->
        {:error, elem(budget_validation, 1), state}

      match?({:error, %Error{}}, lifecycle_validation) ->
        {:error, elem(lifecycle_validation, 1), state}

      match?({:error, %Error{}}, transport_options_validation) ->
        {:error, elem(transport_options_validation, 1), state}

      connected_transport_unavailable?(state) ->
        {:error,
         %Error{
           code: :internal_error,
           message: "#{connected_transport_name(state.transport.type)} client transport is closed"
         }, state}

      saturated?(state) ->
        {:error,
         %Error{
           code: :overloaded,
           message: "client is at max in-flight capacity",
           details: %{resource: :client_requests, retry_after_seconds: 1}
         }, state}

      not server_supports_method?(state, method) ->
        {:error,
         %Error{
           code: :method_not_found,
           message: "server did not advertise support for #{method}",
           details: %{required_capability: Protocol.required_server_capability(method)}
         }, state}

      duplicate_progress_token?(state, get_in(params, ["_meta", "progressToken"])) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "progress tokens must be unique among active requests and tasks"
         }, state}

      true ->
        request_id = Integer.to_string(state.next_request_id)
        ref = make_ref()
        task_augmented = task_augmented_params?(params)

        case safe_build_request(method, params, request_id, state, opts) do
          {:ok, request} ->
            case response_cache_lookup(
                   state,
                   method,
                   params,
                   normalizer,
                   opts,
                   reply_to
                 ) do
              {:hit, result, next_state} ->
                FastestMCP.Client.Trace.annotate_client_request_trace(
                  opts,
                  next_state,
                  method,
                  protocol_version,
                  %{
                    "fastestmcp.cache.hit" => true
                  }
                )

                {:cached, result, next_state}

              {:miss, cache_key, cache_mode, next_state} ->
                start_built_outbound_request(
                  next_state,
                  request,
                  method,
                  params,
                  normalizer,
                  opts,
                  reply_to,
                  request_id,
                  ref,
                  task_augmented,
                  protocol_version,
                  timeout_ms,
                  cache_key,
                  cache_mode
                )

              {:error, %Error{} = error, next_state} ->
                {:error, error, next_state}
            end

          {:error, exception} ->
            {:error, exception, state}
        end
    end
  end

  defp start_built_outbound_request(
         state,
         request,
         method,
         params,
         normalizer,
         opts,
         reply_to,
         request_id,
         ref,
         task_augmented,
         protocol_version,
         timeout_ms,
         cache_key,
         cache_mode
       ) do
    owner = request_owner(reply_to)
    owner_ref = Process.monitor(owner)
    progress_token = get_in(params, ["_meta", "progressToken"])

    entry = %{
      ref: ref,
      reply_to: reply_to,
      normalizer: normalizer,
      method: method,
      direction: :client_to_server,
      request_id: request_id,
      timeout_ms: timeout_ms,
      worker_pid: nil,
      worker_ref: nil,
      request_ref: nil,
      owner_ref: owner_ref,
      task_augmented: task_augmented,
      progress_token: progress_token,
      progress_handler: Keyword.get(opts, :progress_handler),
      last_progress: nil,
      progress_total: nil,
      protocol_version: protocol_version,
      notification_handler: Keyword.get(opts, :on_notification),
      request_params: params,
      request_opts: opts,
      response_cache_key: cache_key,
      response_cache_mode: cache_mode,
      async_trace: Keyword.get(opts, :__fastestmcp_async_trace),
      trace_context: Keyword.get(opts, :__fastestmcp_trace_context),
      subscription_acknowledged?: false,
      subscription_reconnect_attempt: 0,
      reconnect_timer_ref: nil,
      reconnect_token: nil,
      lifecycle: %{session_generation: state.lifecycle.session_generation}
    }

    timer_ref = request_timer(ref, timeout_ms)
    entry = Map.put(entry, :timer_ref, timer_ref)

    next_state =
      state
      |> Map.put(:next_request_id, state.next_request_id + 1)
      |> maybe_store_advertised_client_capabilities(request, method)
      |> put_in([Access.key(:pending), Access.key(:in_flight), ref], entry)
      |> put_in([Access.key(:pending), Access.key(:request_owner_refs), owner_ref], ref)

    case state.transport.type do
      type when type in [:stdio, :in_process] ->
        case safe_connected_transport_command(state.transport, request) do
          :ok ->
            {:ok, ref, request_id, task_augmented,
             %{
               next_state
               | stdio: %{
                   next_state.stdio
                   | pending_stdio_ref: ref,
                     pending_stdio_refs:
                       Map.put(next_state.stdio.pending_stdio_refs, request_id, ref)
                 }
             }}

          {:error, %Error{} = error} ->
            Process.demonitor(owner_ref, [:flush])
            {:error, error, state}
        end

      :streamable_http ->
        {:ok, ref, request_id, task_augmented,
         start_http_request_worker(
           next_state,
           ref,
           request,
           method,
           normalizer,
           timeout_ms,
           opts
         )}
    end
  end

  defp response_cache_lookup(state, method, params, normalizer, opts, reply_to) do
    with {:ok, mode} <- response_cache_mode(opts),
         :ok <- validate_scoped_progress_handler(Keyword.get(opts, :progress_handler)) do
      if response_cache_eligible?(state, method, params, opts, reply_to, mode) do
        key = response_cache_key(state, method, params, normalizer, opts)

        if mode == :use do
          case ResponseCache.get(state.catalog.response_cache, key) do
            {:hit, result, cache} ->
              {:hit, result, %{state | catalog: %{state.catalog | response_cache: cache}}}

            {:miss, cache} ->
              {:miss, key, mode, %{state | catalog: %{state.catalog | response_cache: cache}}}
          end
        else
          {:miss, key, mode, state}
        end
      else
        {:miss, nil, mode, state}
      end
    else
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp response_cache_mode(opts) do
    case Keyword.get(opts, :cache, :use) do
      mode when mode in [:use, :refresh, :bypass] ->
        {:ok, mode}

      mode ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "cache must be :use, :refresh, or :bypass",
           details: %{cache: inspect(mode)}
         }}
    end
  end

  defp validate_scoped_progress_handler(nil) do
    :ok
  end

  defp validate_scoped_progress_handler(handler)
       when is_function(handler, 0) or is_function(handler, 1) do
    :ok
  end

  defp validate_scoped_progress_handler(_handler) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "progress_handler must be a zero- or one-arity function"
     }}
  end

  defp response_cache_eligible?(state, method, params, opts, reply_to, mode) do
    ResponseCache.enabled?(state.catalog.response_cache) and
      state.lifecycle.lifecycle_state == :initialized and
      state.selected_protocol_version == "2026-07-28" and
      Protocol.cache_hinted_method?(method) and
      mode != :bypass and
      match?({:sync, _from}, reply_to) and
      not cursor_param?(params) and
      not mrtr_continuation?(params) and
      not progress_bearing?(params) and
      is_nil(Keyword.get(opts, :progress_handler)) and
      is_nil(Keyword.get(opts, :on_notification)) and
      not per_request_credentials?(opts)
  end

  defp cursor_param?(params) when is_map(params) do
    Map.has_key?(params, "cursor") or Map.has_key?(params, :cursor)
  end

  defp cursor_param?(_params) do
    false
  end

  defp mrtr_continuation?(params) when is_map(params) do
    Enum.any?(
      ["inputResponses", :inputResponses, "requestState", :requestState],
      &Map.has_key?(params, &1)
    )
  end

  defp mrtr_continuation?(_params) do
    false
  end

  defp progress_bearing?(params) when is_map(params) do
    meta = Map.get(params, "_meta") || Map.get(params, :_meta) || %{}

    is_map(meta) and
      (Map.has_key?(meta, "progressToken") or Map.has_key?(meta, :progressToken))
  end

  defp progress_bearing?(_params) do
    false
  end

  defp response_cache_key(state, method, params, normalizer, opts) do
    server_capabilities =
      (state.discovery_result || state.initialize_result || %{})
      |> Map.get("capabilities", %{})

    {
      :fastest_mcp_client_response,
      method,
      normalizer,
      deterministic_digest(params),
      state.selected_protocol_version,
      state.client_info,
      FastestMCP.Client.Codec.modern_client_capabilities(state),
      server_capabilities,
      state.extensions,
      state.roots,
      state.lifecycle.auth_generation,
      request_context_partition(opts),
      state.server_identity
    }
  end

  defp per_request_credentials?(opts) do
    override = FastestMCP.Client.Codec.normalize_request_auth_opts(opts)
    authorization = Map.get(override, "authorization")
    header_authorization = get_in(override, ["headers", "authorization"])

    (is_binary(authorization) and authorization != "") or
      (is_binary(header_authorization) and header_authorization != "")
  end

  defp request_context_partition(opts) do
    opts
    |> FastestMCP.Client.Codec.normalize_request_auth_opts()
    |> Map.delete("authorization")
    |> Map.update("headers", %{}, &Map.delete(&1, "authorization"))
    |> deterministic_digest()
  end

  defp deterministic_digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp maybe_put_scoped_progress_token(params, opts) do
    if not is_nil(Keyword.get(opts, :progress_handler)) and not progress_bearing?(params) do
      token =
        "fastestmcp-progress-" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic]))

      Map.update(params, "_meta", %{"progressToken" => token}, fn meta ->
        meta
        |> Map.new()
        |> Map.put("progressToken", token)
      end)
    else
      params
    end
  end

  def validate_request_budget(reply_to, opts) do
    owner = request_owner(reply_to)

    cond do
      node(owner) == node() and not Process.alive?(owner) ->
        {:error, %Error{code: :cancelled, message: "client request owner exited"}}

      FastestMCP.Deadline.remaining(Keyword.get(opts, :deadline, :infinity)) == 0 ->
        {:error, %Error{code: :timeout, message: "client request deadline elapsed"}}

      true ->
        :ok
    end
  end

  defp request_owner({:sync, {pid, _tag}}) do
    pid
  end

  defp request_owner({:async, pid}) do
    pid
  end

  defp maybe_store_advertised_client_capabilities(state, request, "initialize") do
    %{state | advertised_client_capabilities: get_in(request, ["params", "capabilities"]) || %{}}
  end

  defp maybe_store_advertised_client_capabilities(state, _request, _method) do
    state
  end

  defp start_http_request_worker(
         state,
         ref,
         request,
         method,
         normalizer,
         timeout_ms,
         opts
       ) do
    parent = self()

    snapshot = FastestMCP.Client.TransportSnapshot.new(state)

    {pid, worker_ref} =
      FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
        request_started = fn request_ref ->
          send(parent, {:http_request_started, ref, self(), request_ref})
        end

        result =
          FastestMCP.Client.HTTP.run_http_request(
            request,
            method,
            normalizer,
            timeout_ms,
            snapshot,
            opts,
            request_started
          )

        send(parent, {:http_request_complete, ref, result})
      end)

    state
    |> put_in([Access.key(:pending), Access.key(:in_flight), ref, :worker_pid], pid)
    |> put_in([Access.key(:pending), Access.key(:in_flight), ref, :worker_ref], worker_ref)
    |> put_in([Access.key(:pending), Access.key(:worker_refs), worker_ref], ref)
  end

  defp schedule_modern_subscription_reconnect(state, ref, entry, error, retry_delay) do
    FastestMCP.Client.HTTP.cancel_http_request(entry.request_ref)
    FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))

    if entry.worker_ref do
      Process.demonitor(entry.worker_ref, [:flush])
    end

    attempt = Map.get(entry, :subscription_reconnect_attempt, 0)

    detached_entry =
      entry
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> Map.put(:request_ref, nil)
      |> Map.put(:subscription_acknowledged?, false)
      |> Map.put(:reconnect_timer_ref, nil)
      |> Map.put(:reconnect_token, nil)

    state =
      state
      |> put_in(
        [Access.key(:pending), Access.key(:worker_refs)],
        FastestMCP.Client.RequestOwnership.drop_worker_ref(
          state.pending.worker_refs,
          entry.worker_ref
        )
      )
      |> put_in([Access.key(:pending), Access.key(:in_flight), ref], detached_entry)

    if attempt < state.sse_reconnect.max_attempts and is_integer(retry_delay) do
      reconnect_token = make_ref()

      reconnect_timer_ref =
        Process.send_after(
          self(),
          {:reconnect_modern_subscription, ref, reconnect_token},
          retry_delay
        )

      state
      |> put_in(
        [Access.key(:pending), Access.key(:in_flight), ref, :subscription_reconnect_attempt],
        attempt + 1
      )
      |> put_in(
        [Access.key(:pending), Access.key(:in_flight), ref, :reconnect_timer_ref],
        reconnect_timer_ref
      )
      |> put_in(
        [Access.key(:pending), Access.key(:in_flight), ref, :reconnect_token],
        reconnect_token
      )
    else
      terminal_error = %{
        error
        | details:
            Map.merge(error.details || %{}, %{
              reconnect_attempts: attempt,
              reconnect_exhausted: attempt >= state.sse_reconnect.max_attempts
            })
      }

      complete_http_request(state, ref, {:error, terminal_error})
    end
  end

  defp reopen_modern_subscription(state, ref, entry) do
    request_id = Integer.to_string(state.next_request_id)
    opts = Map.fetch!(entry, :request_opts)
    params = Map.fetch!(entry, :request_params)

    FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))

    entry =
      entry
      |> Map.put(:request_id, request_id)
      |> Map.put(:reconnect_timer_ref, nil)
      |> Map.put(:reconnect_token, nil)

    state =
      state
      |> Map.put(:next_request_id, state.next_request_id + 1)
      |> put_in([Access.key(:pending), Access.key(:in_flight), ref], entry)

    case safe_build_request("subscriptions/listen", params, request_id, state, opts) do
      {:ok, request} ->
        start_http_request_worker(
          state,
          ref,
          request,
          "subscriptions/listen",
          entry.normalizer,
          entry.timeout_ms,
          opts
        )

      {:error, %Error{} = error} ->
        complete_http_request(state, ref, {:error, error})
    end
  end

  def task_augmented_params?(%{"task" => %{}}) do
    true
  end

  def task_augmented_params?(%{
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      }) do
    true
  end

  def task_augmented_params?(_params) do
    false
  end

  defp server_supports_method?(state, method) do
    if method in ["initialize", "server/discover"] do
      true
    else
      capabilities =
        Map.get(state.discovery_result || state.initialize_result || %{}, "capabilities", %{})

      if state.selected_protocol_version == "2026-07-28" and
           method in ["tasks/get", "tasks/update", "tasks/cancel"] do
        Extensions.enabled?(capabilities, Extensions.tasks()) and
          Extensions.enabled?(state.extensions, Extensions.tasks())
      else
        Protocol.server_supports_method?(capabilities, method)
      end
    end
  end

  defp duplicate_progress_token?(_state, nil) do
    false
  end

  defp duplicate_progress_token?(state, token) do
    Enum.any?(state.pending.in_flight, fn {_ref, entry} -> entry.progress_token == token end) or
      Enum.any?(state.tasks.task_registry, fn {_task_id, entry} ->
        entry[:progress_token] == token
      end)
  end

  defp safe_build_request(method, params, request_id, state, opts) do
    request = FastestMCP.Client.Codec.build_request(method, params, request_id, state, opts)

    protocol_version =
      Keyword.get(
        opts,
        :protocol_version,
        FastestMCP.Client.Codec.selected_request_protocol_version(state, method)
      )

    validation =
      if Schema.built_in_method?(method) do
        case Schema.validate_protocol(
               protocol_version,
               :client_to_server,
               :request,
               method,
               request
             ) do
          {:ok, ^request} -> :ok
          {:error, error} -> {:error, error}
        end
      else
        JSONRPC.validate_generic_client_request(request, protocol_version)
      end

    case validation do
      :ok ->
        {:ok, request}

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "invalid #{method} request",
           details: %{violations: error.violations}
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    error in Error -> {:error, error}
  end

  defp cancel_outbound_request(state, ref, reason) do
    case Map.get(state.pending.in_flight, ref) do
      nil ->
        {:error,
         %Error{
           code: :bad_request,
           message: "client request is no longer in flight"
         }}

      %{method: "initialize"} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "the initialize request cannot be cancelled"
         }}

      entry ->
        _ = maybe_send_outbound_cancellation(state, entry, reason)
        {:ok, locally_cancel_outbound_request(state, ref, entry)}
    end
  end

  defp locally_cancel_outbound_request(state, ref, entry) do
    FastestMCP.Client.RequestOwnership.cancel_timer(entry.timer_ref)
    FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))
    FastestMCP.Client.HTTP.cancel_http_request(entry.request_ref)

    if is_pid(entry.worker_pid) do
      Process.exit(entry.worker_pid, :kill)
    end

    if entry.worker_ref do
      Process.demonitor(entry.worker_ref, [:flush])
    end

    FastestMCP.Client.RequestOwnership.reply_request_entry(
      entry,
      {:error,
       %Error{
         code: :cancelled,
         message: "#{entry.method} was cancelled"
       }}
    )

    %{
      state
      | pending: %{
          state.pending
          | in_flight: Map.delete(state.pending.in_flight, ref),
            worker_refs:
              FastestMCP.Client.RequestOwnership.drop_worker_ref(
                state.pending.worker_refs,
                entry.worker_ref
              ),
            request_owner_refs:
              FastestMCP.Client.RequestOwnership.drop_owner_ref(
                state.pending.request_owner_refs,
                entry.owner_ref
              )
        },
        stdio: %{
          state.stdio
          | pending_stdio_ref:
              if(state.stdio.pending_stdio_ref == ref) do
                nil
              else
                state.stdio.pending_stdio_ref
              end,
            pending_stdio_refs: Map.delete(state.stdio.pending_stdio_refs, entry.request_id)
        }
    }
  end

  defp maybe_send_outbound_cancellation(_state, %{method: "initialize"}, _reason) do
    :ok
  end

  defp maybe_send_outbound_cancellation(
         %{transport: %{type: :stdio, port: port}},
         _entry,
         _reason
       )
       when not is_port(port) do
    :ok
  end

  defp maybe_send_outbound_cancellation(state, entry, reason) do
    params =
      %{"requestId" => entry.request_id}
      |> FastestMCP.Client.Codec.maybe_put("reason", reason)

    opts = [timeout_ms: min(state.timeout_ms, 1000)]

    case state.transport.type do
      type when type in [:stdio, :in_process] ->
        FastestMCP.Client.Requests.send_client_notification(
          state,
          "notifications/cancelled",
          params,
          opts
        )

      :streamable_http when state.selected_protocol_version == "2026-07-28" ->
        :ok

      # Modern HTTP cancellation is closing the request-scoped response.
      :streamable_http ->
        snapshot = FastestMCP.Client.TransportSnapshot.new(state)

        FastestMCP.Client.Workers.start(state.worker_supervisor, fn ->
          _ =
            FastestMCP.Client.Requests.send_client_notification(
              snapshot,
              "notifications/cancelled",
              params,
              opts
            )
        end)

        :ok
    end
  end

  defp cancel_request_for_dead_owner(state, owner_ref) do
    case Map.pop(state.pending.request_owner_refs, owner_ref) do
      {nil, _owner_refs} ->
        state

      {ref, owner_refs} ->
        case Map.get(state.pending.in_flight, ref) do
          nil ->
            %{state | pending: %{state.pending | request_owner_refs: owner_refs}}

          entry ->
            _ = maybe_send_outbound_cancellation(state, entry, "request owner exited")

            state
            |> put_in([Access.key(:pending), Access.key(:request_owner_refs)], owner_refs)
            |> locally_cancel_outbound_request(ref, entry)
        end
    end
  end

  defp normalize_client_info(nil) do
    %{
      "name" => "FastestMCP.Client",
      "version" => application_version()
    }
  end

  defp normalize_client_info(%{} = info) do
    Map.new(info, fn {key, value} -> {to_string(key), value} end)
  end

  defp application_version do
    case Application.spec(:fastest_mcp, :vsn) do
      nil -> "0.2.0"
      version when is_list(version) -> List.to_string(version)
      version -> to_string(version)
    end
  end

  def register_tracked_task(%Client{pid: pid}, task_id, opts) do
    GenServer.call(
      pid,
      {:register_task, to_string(task_id), Keyword.get(opts, :kind, :generic),
       Keyword.get(opts, :target), Keyword.get(opts, :output_validator)}
    )
  end

  defp invalidate_tool_catalog(state, reason) do
    if load = state.catalog.tool_catalog_load do
      Process.demonitor(load.monitor_ref, [:flush])

      error = %Error{
        code: :bad_request,
        message: "tool catalog was invalidated while loading",
        details: %{reason: reason}
      }

      Enum.each(load.waiters, &GenServer.reply(&1, {:error, error}))
    end

    generation = state.catalog.tool_catalog.generation + 1

    %{
      state
      | catalog: %{
          state.catalog
          | tool_catalog: ToolCatalog.new(generation),
            tool_catalog_ready?: false,
            tool_catalog_load: nil
        }
    }
  end

  defp invalidate_response_cache(state) do
    %{
      state
      | catalog: %{
          state.catalog
          | response_cache: ResponseCache.clear(state.catalog.response_cache)
        }
    }
  end

  defp invalidate_client_caches(state, reason) do
    state
    |> invalidate_tool_catalog(reason)
    |> invalidate_response_cache()
  end

  defp rotate_auth_partition(state) do
    state
    |> update_in([Access.key(:lifecycle), Access.key(:auth_generation)], &(&1 + 1))
    |> invalidate_client_caches(:authentication_changed)
  end

  defp maybe_invalidate_connection_cache(previous, next) do
    if previous.selected_protocol_version != next.selected_protocol_version or
         previous.server_identity != next.server_identity do
      invalidate_client_caches(next, :connection_identity_changed)
    else
      next
    end
  end

  defp server_identity(%{"serverInfo" => server_info}) when is_map(server_info) do
    server_info
  end

  defp server_identity(%{"_meta" => %{} = meta}) do
    Map.get(meta, "io.modelcontextprotocol/serverInfo")
  end

  defp server_identity(_result) do
    nil
  end

  defp update_task_status(state, task_id, task) do
    entry =
      state.tasks.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> Map.put(:status, task)
      |> maybe_clear_terminal_task_progress(task)

    state = put_in(state.tasks.task_registry[task_id], entry)

    Enum.each(Map.values(entry.callbacks), fn callback ->
      maybe_invoke_notification_handler(callback, task)
    end)

    ready_waiters =
      entry.waiters
      |> Enum.filter(fn {_waiter_ref, waiter} ->
        FastestMCP.Client.Execution.task_matches_target_status?(task, waiter.target_statuses)
      end)

    state =
      Enum.reduce(ready_waiters, state, fn {waiter_ref, waiter}, acc ->
        FastestMCP.Client.RequestOwnership.cancel_timer(waiter.timer_ref)
        GenServer.reply(waiter.from, {:ok, task})
        update_in(acc.tasks.task_registry[task_id][:waiters], &Map.delete(&1, waiter_ref))
      end)

    state
  end

  def retain_task_progress(state, request, {:ok, result}) when is_map(result) do
    task =
      case result do
        %{"task" => %{} = task} -> task
        %{"resultType" => "task", "taskId" => _task_id} = task -> task
        _other -> nil
      end

    retain_task_progress_entry(state, request, task)
  end

  def retain_task_progress(state, _request, _result) do
    state
  end

  defp retain_task_progress_entry(state, _request, nil) do
    state
  end

  defp retain_task_progress_entry(state, request, task) do
    progress_token = request.progress_token
    progress_handler = request.progress_handler

    if is_nil(progress_token) and is_nil(progress_handler) do
      state
    else
      case FastestMCP.Client.Execution.task_id_from_status(task) do
        nil ->
          state

        task_id ->
          task_id = to_string(task_id)
          existing = Map.get(state.tasks.task_registry, task_id, %{})
          status = existing[:status] || task

          if FastestMCP.Client.Execution.terminal_task_status?(status) do
            state
          else
            entry =
              existing
              |> Map.put_new(:result, nil)
              |> Map.put_new(:callbacks, %{})
              |> Map.put_new(:waiters, %{})
              |> Map.put_new(:origin_method, request.method)
              |> Map.put(:status, status)
              |> Map.put(:progress_token, progress_token)
              |> Map.put(:progress_handler, progress_handler)
              |> Map.put(:last_progress, request.last_progress)
              |> Map.put(:progress_total, request.progress_total)

            put_in(state.tasks.task_registry[task_id], entry)
          end
      end
    end
  end

  defp maybe_clear_terminal_task_progress(entry, task) do
    if FastestMCP.Client.Execution.terminal_task_status?(task) do
      clear_task_progress(entry)
    else
      entry
    end
  end

  defp clear_task_progress(entry) do
    entry
    |> Map.put(:progress_token, nil)
    |> Map.put(:progress_handler, nil)
    |> Map.put(:last_progress, nil)
    |> Map.put(:progress_total, nil)
  end

  def recoverable_missing_http_session?(state, method, 404) do
    method != "initialize" and is_binary(state.session_id) and state.session_id != ""
  end

  def recoverable_missing_http_session?(_state, _method, _status) do
    false
  end

  def maybe_report_stale_session(
        %{session_id: session_id, lifecycle: %{lifecycle_state: :initialized}} = state,
        method,
        404,
        %Error{} = error
      )
      when is_binary(session_id) and session_id != "" and
             method not in ["initialize", "notifications/initialized"] do
    send(
      state.client_pid,
      {:stale_session_detected, error, session_id, state.lifecycle.session_generation}
    )

    :ok
  end

  def maybe_report_stale_session(_state, _method, _status, _error) do
    :ok
  end

  defp perform_http_session_recovery(recovery_request_id, timeout_ms, state, opts) do
    recovery_state = %{
      FastestMCP.Client.TransportSnapshot.new(state)
      | session_id: nil,
        initialize_result: nil
    }

    recovery_opts =
      opts
      |> Keyword.delete(:request_started)
      |> Keyword.put(:protocol_version, "2025-11-25")

    with {:ok, initialize_request} <-
           safe_build_request(
             "initialize",
             %{},
             recovery_request_id,
             recovery_state,
             recovery_opts
           ),
         {:ok, initialize_result, headers, _cache_hint} <-
           FastestMCP.Client.HTTP.run_http_request(
             initialize_request,
             "initialize",
             {:initialize, "2025-11-25"},
             timeout_ms,
             recovery_state,
             recovery_opts,
             fn _request_ref -> :ok end
           ),
         recovered_session_id <-
           FastestMCP.Client.Codec.response_header(headers, "mcp-session-id"),
         recovered_state <- %{
           recovery_state
           | session_id: recovered_session_id,
             initialize_result: initialize_result,
             advertised_client_capabilities:
               get_in(initialize_request, ["params", "capabilities"]) || %{}
         },
         :ok <-
           FastestMCP.Client.Requests.send_client_notification(
             recovered_state,
             "notifications/initialized",
             %{},
             recovery_opts
           ) do
      {:ok, initialize_result, headers, recovered_state}
    end
  end

  defp pop_completed_http_entry(state, ref) do
    case Map.pop(state.pending.in_flight, ref) do
      {nil, _in_flight} ->
        {:error, state}

      {%{timer_ref: timer_ref, worker_ref: worker_ref} = entry, in_flight} ->
        FastestMCP.Client.RequestOwnership.cancel_timer(timer_ref)
        FastestMCP.Client.HTTP.cancel_http_request(entry.request_ref)

        if worker_ref do
          Process.demonitor(worker_ref, [:flush])
        end

        {:ok, entry,
         %{
           state
           | pending: %{
               state.pending
               | in_flight: in_flight,
                 worker_refs:
                   FastestMCP.Client.RequestOwnership.drop_worker_ref(
                     state.pending.worker_refs,
                     worker_ref
                   ),
                 request_owner_refs:
                   FastestMCP.Client.RequestOwnership.drop_owner_ref(
                     state.pending.request_owner_refs,
                     entry.owner_ref
                   )
             }
         }}
    end
  end

  defp begin_session_recovery(%{lifecycle: %{recovery: %{}}} = state, nil, _error) do
    state
  end

  defp begin_session_recovery(%{lifecycle: %{recovery: %{} = recovery}} = state, entry, error) do
    put_in(state.lifecycle.recovery.failures, [{entry, error} | recovery.failures])
  end

  defp begin_session_recovery(state, entry, error) do
    parent = self()
    generation = state.lifecycle.session_generation

    recovery_request_id =
      "reinitialize-session-#{generation}-#{System.unique_integer([:positive])}"

    recovery_state = %{
      FastestMCP.Client.TransportSnapshot.new(state)
      | session_id: nil,
        initialize_result: nil
    }

    timeout_ms = state.timeout_ms

    {pid, monitor_ref} =
      FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
        result =
          perform_http_session_recovery(
            recovery_request_id,
            timeout_ms,
            recovery_state,
            []
          )

        send(parent, {:session_recovery_complete, generation, result})
      end)

    {state, reopen_session_stream?} = suspend_session_stream_for_recovery(state)

    state = %{
      state
      | lifecycle: %{
          state.lifecycle
          | lifecycle_state: :recovering,
            recovery: %{
              pid: pid,
              monitor_ref: monitor_ref,
              generation: generation,
              failures:
                if(is_nil(entry)) do
                  []
                else
                  [{entry, error}]
                end,
              queue: [],
              stream_waiters: [],
              reopen_session_stream?: reopen_session_stream?
            }
        }
    }

    invalidate_client_caches(state, :session_recovery)
  end

  defp begin_stream_session_recovery(
         %{lifecycle: %{recovery: %{} = recovery}} = state,
         from,
         _error
       ) do
    put_in(state.lifecycle.recovery.stream_waiters, [from | recovery.stream_waiters])
  end

  defp begin_stream_session_recovery(state, from, _original_error) do
    parent = self()
    generation = state.lifecycle.session_generation

    recovery_request_id =
      "reinitialize-stream-#{generation}-#{System.unique_integer([:positive])}"

    recovery_state = %{
      FastestMCP.Client.TransportSnapshot.new(state)
      | session_id: nil,
        initialize_result: nil
    }

    timeout_ms = state.timeout_ms

    {pid, monitor_ref} =
      FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
        result =
          perform_http_session_recovery(
            recovery_request_id,
            timeout_ms,
            recovery_state,
            []
          )

        send(parent, {:session_recovery_complete, generation, result})
      end)

    state = %{
      state
      | lifecycle: %{
          state.lifecycle
          | lifecycle_state: :recovering,
            recovery: %{
              pid: pid,
              monitor_ref: monitor_ref,
              generation: generation,
              failures: [],
              queue: [],
              stream_waiters: [from],
              reopen_session_stream?: false
            }
        }
    }

    invalidate_client_caches(state, :session_recovery)
  end

  defp suspend_session_stream_for_recovery(%{session_stream: nil} = state) do
    {state, false}
  end

  defp suspend_session_stream_for_recovery(%{session_stream: session_stream} = state) do
    FastestMCP.Client.HTTP.cancel_http_request(session_stream.request_ref)

    if is_pid(session_stream.pid) do
      Process.exit(session_stream.pid, :kill)
    end

    if session_stream.monitor_ref do
      Process.demonitor(session_stream.monitor_ref, [:flush])
    end

    {%{state | session_stream: nil}, true}
  end

  defp finish_session_recovery(
         %{lifecycle: %{recovery: %{generation: generation} = recovery}} = state,
         generation,
         {:ok, initialize_result, _headers, recovered_state}
       ) do
    Process.demonitor(recovery.monitor_ref, [:flush])

    state = %{
      state
      | session_id: recovered_state.session_id,
        initialize_result: initialize_result,
        advertised_client_capabilities: recovered_state.advertised_client_capabilities,
        server_identity: server_identity(initialize_result),
        lifecycle: %{
          state.lifecycle
          | lifecycle_state: :initialized,
            session_generation: generation + 1,
            recovery: nil
        }
    }

    Enum.each(recovery.failures, fn {entry, error} ->
      FastestMCP.Client.RequestOwnership.reply_request_entry(
        entry,
        {:error, FastestMCP.Client.HTTP.original_request_not_replayed(error)}
      )
    end)

    snapshot = FastestMCP.Client.TransportSnapshot.new(state)
    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:ok, snapshot}))

    state
    |> FastestMCP.Client.HTTP.maybe_reopen_recovered_session_stream(
      recovery.reopen_session_stream?
    )
    |> FastestMCP.Client.HTTP.flush_recovery_queue(Enum.reverse(recovery.queue))
    |> release_ready_waiters()
  end

  defp finish_session_recovery(
         %{lifecycle: %{recovery: %{generation: generation} = recovery}} = state,
         generation,
         {:error, recovery_error}
       ) do
    Process.demonitor(recovery.monitor_ref, [:flush])

    Enum.each(recovery.failures, fn {entry, original_error} ->
      FastestMCP.Client.RequestOwnership.reply_request_entry(
        entry,
        {:error, session_recovery_failure(original_error, recovery_error, state.session_id)}
      )
    end)

    Enum.each(recovery.queue, fn operation ->
      FastestMCP.Client.HTTP.fail_queued_recovery_operation(operation, recovery_error)
    end)

    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:error, recovery_error}))

    next_state =
      %{
        state
        | session_id: nil,
          initialize_result: nil,
          advertised_client_capabilities: nil,
          lifecycle: %{state.lifecycle | lifecycle_state: :failed, recovery: nil}
      }
      |> invalidate_client_caches(:session_recovery_failed)

    fail_ready_waiters(next_state, recovery_error)
  end

  defp finish_session_recovery(state, _generation, _result) do
    state
  end

  defp session_recovery_failure(original_error, recovery_error, stale_session_id) do
    %Error{
      code: :internal_error,
      message: "HTTP MCP session recovery failed",
      details: %{
        stale_session_id: stale_session_id,
        original_error: original_error.message,
        recovery_error: Exception.message(recovery_error)
      }
    }
  end

  def handle_server_request(
        %{"method" => _method} = message,
        state,
        opts
      ) do
    if self() == state.client_pid do
      process_server_request(message, expire_callback_tasks(state), opts)
    else
      GenServer.call(
        state.client_pid,
        {:handle_server_request, message, opts},
        state.timeout_ms + 1000
      )
    end
  end

  def process_server_request(%{"method" => method} = message, state, opts) do
    opts = Keyword.put(opts, :callback_method, method)
    request_id = Map.fetch!(message, "id")

    cond do
      not inbound_request_allowed_by_lifecycle?(state, method) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error, lifecycle_error(state, "handle #{method}")},
                 opts
               ) do
          {:ok, state}
        end

      not Protocol.client_supports_method?(
        state.advertised_client_capabilities || %{},
        method,
        Map.get(message, "params", %{})
      ) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :method_not_found,
                    message: "#{method} was not negotiated for this client session"
                  }},
                 opts
               ) do
          {:ok, state}
        end

      MapSet.member?(state.callbacks.callback_request_ids, request_id) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :invalid_request,
                    message: "JSON-RPC request id has already been used in this session"
                  }},
                 opts
               ) do
          {:ok, state}
        end

      MapSet.size(state.callbacks.callback_request_ids) >= state.max_callback_request_ids ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :overloaded,
                    message: "JSON-RPC request id capacity has been reached",
                    details: %{resource: :request_ids, retry_after_seconds: 1},
                    terminate_session_after_delivery: true
                  }},
                 opts
               ) do
          send(state.client_pid, :callback_request_id_capacity_exhausted)
          {:ok, state}
        end

      true ->
        next_state =
          update_in(state.callbacks.callback_request_ids, &MapSet.put(&1, request_id))

        do_process_server_request(message, next_state, opts)
    end
  end

  defp inbound_request_allowed_by_lifecycle?(
         %{lifecycle: %{lifecycle_state: :initialized}},
         _method
       ) do
    true
  end

  defp inbound_request_allowed_by_lifecycle?(
         %{lifecycle: %{lifecycle_state: :initializing}},
         "ping"
       ) do
    true
  end

  defp inbound_request_allowed_by_lifecycle?(_state, _method) do
    false
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "ping"},
         state,
         opts
       ) do
    with :ok <- post_client_response(state, id, {:ok, %{}}, opts) do
      {:ok, state}
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "roots/list"},
         %{roots_supported?: true} = state,
         opts
       ) do
    result = %{"roots" => Enum.map(state.roots, &Root.to_wire/1)}

    with :ok <- post_client_response(state, id, {:ok, result}, opts) do
      {:ok, state}
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "sampling/createMessage", "params" => params},
         state,
         opts
       ) do
    case FastestMCP.Client.Callbacks.validate_sampling_request_capabilities(params, state) do
      {:ok, sampling_validators} ->
        maybe_start_callback_task(
          state,
          id,
          "sampling/createMessage",
          params,
          state.sampling_handler,
          fn handler, context ->
            FastestMCP.Client.Callbacks.sampling_response(
              handler,
              params,
              context,
              sampling_validators
            )
          end,
          opts
        )

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "elicitation/create", "params" => params},
         state,
         opts
       ) do
    {handler, executor} =
      case Map.get(params, "mode", "form") do
        "url" ->
          {state.url_elicitation_handler,
           fn callback, context ->
             FastestMCP.Client.Callbacks.url_elicitation_response(callback, params, context)
           end}

        _form ->
          {state.elicitation_handler,
           fn callback, context ->
             FastestMCP.Client.Callbacks.elicitation_response(callback, params, context)
           end}
      end

    case FastestMCP.Client.Callbacks.validate_elicitation_request_schema(
           params,
           state.schema_options
         ) do
      :ok ->
        maybe_start_callback_task(
          state,
          id,
          "elicitation/create",
          params,
          handler,
          executor,
          opts
        )

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/get", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/get") do
      case fetch_callback_task(state, task_id) do
        {:ok, task} ->
          with :ok <-
                 post_client_response(
                   state,
                   id,
                   {:ok, TaskWire.task(task, mask_error_details: true)},
                   opts
                 ) do
            {:ok, state}
          end

        :error ->
          post_invalid_task_error(state, id, task_id, opts)
      end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/result", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/result") do
      case fetch_callback_task(state, task_id) do
        {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
          with :ok <- post_client_response(state, id, callback_task_result_response(task), opts) do
            {:ok, state}
          end

        {:ok, _task} ->
          {:ok, register_callback_result_waiter(state, task_id, id, opts)}

        :error ->
          post_invalid_task_error(state, id, task_id, opts)
      end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/list", "params" => params},
         state,
         opts
       ) do
    next_state = expire_callback_tasks(state)

    case list_callback_tasks(next_state, params) do
      {:ok, page} ->
        with :ok <-
               post_client_response(
                 state,
                 id,
                 {:ok, TaskWire.task_list(page, mask_error_details: true)},
                 opts
               ) do
          {:ok, next_state}
        end

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, next_state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/cancel", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/cancel") do
      case cancel_callback_task(state, task_id) do
        {:ok, next_state, task} ->
          with :ok <-
                 post_client_response(
                   state,
                   id,
                   {:ok, TaskWire.task(task, mask_error_details: true)},
                   opts
                 ) do
            {:ok, next_state}
          end

        {:error, :not_found} ->
          post_invalid_task_error(state, id, task_id, opts)

        {:error, %Error{} = error} ->
          with :ok <- post_client_response(state, id, {:error, error}, opts) do
            {:ok, state}
          end
      end
    end
  end

  defp do_process_server_request(%{"id" => id, "method" => method}, state, opts) do
    with :ok <-
           post_client_response(
             state,
             id,
             {:error,
              %Error{
                code: :method_not_found,
                message: "unsupported client callback #{inspect(method)}"
              }},
             opts
           ) do
      {:ok, state}
    end
  end

  defp post_client_response(state, id, {:ok, result}, opts) do
    payload =
      %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      |> JSONValue.stringify_keys()

    case validate_client_callback_payload(payload, opts) do
      :ok ->
        await_client_callback_post(state, payload, opts)

      {:error, %Error{} = error} ->
        post_client_response(state, id, {:error, error}, opts)
    end
  end

  defp post_client_response(state, id, {:error, %Error{} = error}, opts) do
    payload =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => JSONRPC.error_code(error),
          "message" => error.message,
          "data" => FastestMCP.Client.HTTP.callback_error_data(error)
        }
      }
      |> FastestMCP.Client.Codec.maybe_put("_meta", error.meta)
      |> JSONValue.stringify_keys()

    case validate_client_callback_payload(payload, opts) do
      :ok -> await_client_callback_post(state, payload, opts)
      {:error, %Error{} = validation_error} -> {:error, validation_error}
    end
  end

  defp validate_client_callback_payload(payload, opts) do
    method = Keyword.fetch!(opts, :callback_method)

    schema_selector =
      cond do
        Map.has_key?(payload, "error") -> {:error_response, nil}
        Keyword.get(opts, :task_response, false) -> {:task_response, method}
        true -> {:response, method}
      end

    {kind, schema_method} = schema_selector

    case Schema.validate_protocol(
           "2025-11-25",
           :client_to_server,
           kind,
           schema_method,
           payload
         ) do
      {:ok, ^payload} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "client callback returned an invalid #{method} result",
           details: %{violations: error.violations},
           exposure: %{mask_error_details: true, component_type: :client_callback}
         }}
    end
  end

  defp post_client_response_async(state, id, response, opts) do
    snapshot = FastestMCP.Client.TransportSnapshot.new(state)

    FastestMCP.Client.Workers.start(state.worker_supervisor, fn ->
      _ = post_client_response(snapshot, id, response, opts)
    end)

    :ok
  end

  defp await_client_callback_post(
         %{transport: %{type: type} = transport},
         payload,
         _opts
       )
       when type in [:stdio, :in_process] do
    safe_connected_transport_command(transport, payload)
  end

  defp await_client_callback_post(state, payload, opts) do
    caller = self()
    ref = make_ref()

    snapshot = FastestMCP.Client.TransportSnapshot.new(state)

    FastestMCP.Client.Workers.start(state.worker_supervisor, fn ->
      send(
        caller,
        {:client_callback_post_complete, ref, do_post_client_response(snapshot, payload, opts)}
      )
    end)

    receive do
      {:client_callback_post_complete, ^ref, result} ->
        result
    after
      state.timeout_ms ->
        {:error,
         %Error{
           code: :timeout,
           message: "client callback response POST timed out",
           details: %{timeout_ms: state.timeout_ms}
         }}
    end
  end

  defp do_post_client_response(state, payload, opts) do
    opts = Keyword.put(opts, :request, payload)

    result =
      HTTPClientTransport.request(:post, state.transport.base_url,
        json: payload,
        headers:
          FastestMCP.Client.HTTP.transport_headers(
            [
              {"accept", "application/json, text/event-stream"},
              {"content-type", "application/json"},
              {"connection", "close"}
            ],
            state,
            opts
          ),
        timeout_ms: state.timeout_ms
      )

    case result do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      {:ok, status, _headers, body} ->
        error = %Error{
          code: :internal_error,
          message: "client callback response was rejected",
          details: %{status: status, body: FastestMCP.Client.Codec.decode_json_if_possible(body)}
        }

        maybe_report_stale_session(state, Keyword.get(opts, :callback_method), status, error)
        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to POST client callback response",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_callback_task(state, id, method, params, handler, executor, opts) do
    case safe_parse_task_request(params) do
      {:ok, {task_request, ttl_ms}} ->
        cond do
          not task_request ->
            if is_nil(handler) do
              with :ok <-
                     post_client_response(
                       state,
                       id,
                       {:error,
                        %Error{
                          code: :bad_request,
                          message: missing_callback_handler_message(method)
                        }},
                       opts
                     ) do
                {:ok, state}
              end
            else
              {:ok, start_callback_request(state, id, method, params, handler, executor, opts)}
            end

          is_nil(handler) ->
            with :ok <-
                   post_client_response(
                     state,
                     id,
                     {:error,
                      %Error{
                        code: :bad_request,
                        message: missing_callback_handler_message(method)
                      }},
                     opts
                   ) do
              {:ok, state}
            end

          true ->
            task_id = TaskId.generate()
            submitted_at = System.system_time(:millisecond)
            task = new_callback_task(task_id, method, submitted_at, ttl_ms)
            create_result = callback_task_create_result(task)

            task_response_opts = Keyword.put(opts, :task_response, true)

            with :ok <- post_client_response(state, id, {:ok, create_result}, task_response_opts) do
              context = callback_context(state, id, method, params, task_id)

              task =
                task
                |> Map.put(:context, context)
                |> Map.put(:params, params)
                |> Map.put(:last_progress, nil)
                |> Map.put(:progress_total, nil)

              {:ok,
               start_callback_task(state, task, fn ->
                 case executor.(handler, context) do
                   {:ok, result} ->
                     FastestMCP.Client.Callbacks.validate_callback_result!(method, result)
                     {:ok, result}

                   {:error, %Error{} = error} ->
                     {:error, error}
                 end
               end)}
            end
        end

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp start_callback_request(state, id, method, params, handler, executor, opts) do
    parent = self()
    context = callback_context(state, id, method, params, nil)
    trace_context = callback_trace_context(params)

    {:ok, pid} =
      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        result = Telemetry.with_context(trace_context, fn -> executor.(handler, context) end)
        send(parent, {:callback_request_complete, id, result})
      end)

    monitor_ref = Process.monitor(pid)

    request = %{
      id: id,
      method: method,
      direction: :server_to_client,
      params: params,
      context: context,
      opts: opts,
      pid: pid,
      monitor_ref: monitor_ref,
      cancelled?: false,
      last_progress: nil,
      progress_total: nil
    }

    state
    |> put_in([Access.key(:callbacks), Access.key(:callback_requests), id], request)
    |> put_in(
      [Access.key(:callbacks), Access.key(:callback_worker_refs), monitor_ref],
      {:request, id}
    )
  end

  defp callback_context(state, id, method, params, task_id) do
    %CallbackContext{
      client: %Client{pid: state.client_pid},
      request_id: id,
      method: method,
      direction: :server_to_client,
      progress_token: get_in(params, ["_meta", "progressToken"]),
      task_id: task_id,
      sampling_tools: state.sampling_tools,
      sampling_context: state.sampling_context,
      cancellation_ref: :atomics.new(1, []),
      cancelled?: false
    }
  end

  defp start_callback_task(state, task, executor) do
    parent = self()
    trace_context = callback_trace_context(task.params)

    {:ok, pid} =
      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        result =
          Telemetry.with_context(trace_context, fn ->
            try do
              executor.()
            rescue
              error in Error ->
                {:error, error}

              error ->
                {:error,
                 FastestMCP.Client.HTTP.callback_failure(
                   task.method,
                   :internal_error,
                   Exception.message(error),
                   %{kind: inspect(error.__struct__)}
                 )}
            catch
              :exit, reason ->
                {:error,
                 FastestMCP.Client.HTTP.callback_failure(
                   task.method,
                   :internal_error,
                   "client callback task exited",
                   %{reason: inspect(reason)}
                 )}

              kind, reason ->
                {:error,
                 FastestMCP.Client.HTTP.callback_failure(
                   task.method,
                   :internal_error,
                   "client callback task failed",
                   %{kind: inspect(kind), reason: inspect(reason)}
                 )}
            end
          end)

        send(parent, {:callback_task_complete, task.id, result})
      end)

    monitor_ref = Process.monitor(pid)

    task =
      task
      |> Map.put(:pid, pid)
      |> Map.put(:monitor_ref, monitor_ref)

    state
    |> put_in([Access.key(:callbacks), Access.key(:callback_tasks), task.id], task)
    |> put_in([Access.key(:callbacks), Access.key(:callback_task_refs), monitor_ref], task.id)
  end

  defp callback_trace_context(params) when is_map(params) do
    params
    |> Map.get("_meta", %{})
    |> Telemetry.extract_trace_context()
  end

  defp complete_callback_task(state, task_id, status, result, error) do
    case fetch_callback_task(state, task_id) do
      {:ok, task} ->
        now = System.system_time(:millisecond)

        if task.monitor_ref do
          Process.demonitor(task.monitor_ref, [:flush])
        end

        completed_task =
          task
          |> Map.put(:status, status)
          |> Map.put(:result, result)
          |> Map.put(:error, error)
          |> Map.put(:completed_at, now)
          |> Map.put(:updated_at, now)
          |> Map.put(:expires_at, now + task.ttl_ms)
          |> Map.put(:pid, nil)
          |> Map.put(:monitor_ref, nil)

        next_state =
          state
          |> put_in(
            [Access.key(:callbacks), Access.key(:callback_tasks), task_id],
            completed_task
          )
          |> update_in(
            [Access.key(:callbacks), Access.key(:callback_task_refs)],
            &Map.delete(&1, task.monitor_ref)
          )
          |> maybe_track_url_callback_task(completed_task)

        maybe_post_callback_task_notification(next_state, completed_task)
        resolve_callback_result_waiters(next_state, completed_task)

      :error ->
        state
    end
  end

  defp cancel_callback_task(state, task_id) do
    case fetch_callback_task(state, task_id) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        {:error,
         %Error{
           code: :bad_request,
           message: "background task is already in a terminal status",
           details: %{status: status}
         }}

      {:ok, task} ->
        mark_callback_cancelled(task.context)

        if is_pid(task.pid) and Process.alive?(task.pid) do
          Process.exit(task.pid, :kill)
        end

        cancelled_state = complete_callback_task(state, task_id, :cancelled, nil, nil)
        {:ok, cancelled_state, Map.fetch!(cancelled_state.callbacks.callback_tasks, task_id)}

      :error ->
        {:error, :not_found}
    end
  end

  defp handle_callback_task_down(state, worker_ref, reason) do
    case Map.pop(state.callbacks.callback_task_refs, worker_ref) do
      {nil, _callback_task_refs} ->
        state

      {task_id, callback_task_refs} ->
        state = %{state | callbacks: %{state.callbacks | callback_task_refs: callback_task_refs}}

        case fetch_callback_task(state, task_id) do
          {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
            state

          {:ok, task} ->
            complete_callback_task(
              state,
              task_id,
              :failed,
              nil,
              FastestMCP.Client.HTTP.callback_failure(
                task.target,
                :internal_error,
                "client callback task crashed",
                %{reason: inspect(reason)}
              )
            )

          :error ->
            state
        end
    end
  end

  defp handle_callback_worker_down(state, _worker_ref, :normal) do
    state
  end

  defp handle_callback_worker_down(state, worker_ref, reason) do
    case Map.pop(state.callbacks.callback_worker_refs, worker_ref) do
      {nil, _refs} ->
        state

      {{:request, request_id}, refs} ->
        case Map.pop(state.callbacks.callback_requests, request_id) do
          {nil, _requests} ->
            %{state | callbacks: %{state.callbacks | callback_worker_refs: refs}}

          {request, requests} ->
            error =
              FastestMCP.Client.HTTP.callback_failure(
                request.method,
                :internal_error,
                "client callback worker crashed",
                %{reason: inspect(reason)}
              )

            next_state =
              %{
                state
                | callbacks: %{
                    state.callbacks
                    | callback_worker_refs: refs,
                      callback_requests: requests
                  }
              }

            post_client_response_async(next_state, request_id, {:error, error}, request.opts)
            next_state
        end
    end
  end

  defp cancel_inbound_callback(state, request_id) do
    case Map.pop(state.callbacks.callback_requests, request_id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        mark_callback_cancelled(request.context)
        _ = Task.Supervisor.terminate_child(state.worker_supervisor, request.pid)
        Process.demonitor(request.monitor_ref, [:flush])

        %{
          state
          | callbacks: %{
              state.callbacks
              | callback_requests: requests,
                callback_worker_refs:
                  Map.delete(state.callbacks.callback_worker_refs, request.monitor_ref)
            }
        }
    end
  end

  defp mark_callback_cancelled(%CallbackContext{cancellation_ref: cancellation_ref})
       when not is_nil(cancellation_ref) do
    :ok = :atomics.put(cancellation_ref, 1, 1)
  end

  defp mark_callback_cancelled(_context) do
    :ok
  end

  defp maybe_track_url_elicitation(
         state,
         %{params: %{"mode" => "url"} = params},
         {:ok, %{"action" => "accept"}}
       ) do
    case URLElicitation.parse(params) do
      {:ok, request} ->
        put_in(state.callbacks.pending_url_elicitations[request.elicitation_id], request)

      {:error, _error} ->
        state
    end
  end

  defp maybe_track_url_elicitation(state, _request, _result) do
    state
  end

  defp maybe_track_url_callback_task(
         state,
         %{
           params: %{"mode" => "url"} = params,
           status: :completed,
           result: %{"action" => "accept"}
         }
       ) do
    case URLElicitation.parse(params) do
      {:ok, request} ->
        put_in(state.callbacks.pending_url_elicitations[request.elicitation_id], request)

      {:error, _error} ->
        state
    end
  end

  defp maybe_track_url_callback_task(state, _task) do
    state
  end

  def expire_callback_tasks(state) do
    now = System.system_time(:millisecond)

    expired_ids =
      state.callbacks.callback_tasks
      |> Enum.filter(fn {_task_id, task} ->
        is_integer(task.expires_at) and task.expires_at <= now
      end)
      |> Enum.map(fn {task_id, _task} -> task_id end)

    Enum.reduce(expired_ids, state, fn task_id, acc ->
      update_in(acc.callbacks.callback_tasks, &Map.delete(&1, task_id))
    end)
  end

  defp fetch_callback_task(state, task_id) do
    case Map.fetch(state.callbacks.callback_tasks, to_string(task_id)) do
      {:ok, task} -> {:ok, task}
      :error -> :error
    end
  end

  defp list_callback_tasks(state, params) do
    tasks =
      state.callbacks.callback_tasks
      |> Map.values()
      |> Enum.sort_by(&{-&1.submitted_at, &1.id})

    with {:ok, page_size} <- normalize_page_size(Map.get(params, "pageSize")),
         {:ok, start_index} <- callback_cursor_start_index(tasks, Map.get(params, "cursor")) do
      page =
        case page_size do
          nil -> Enum.drop(tasks, start_index)
          value -> Enum.slice(tasks, start_index, value)
        end

      next_cursor =
        if is_integer(page_size) and start_index + page_size < length(tasks) and page != [] do
          encode_callback_task_cursor(List.last(page).id)
        end

      {:ok, %{tasks: page, next_cursor: next_cursor}}
    end
  end

  defp normalize_page_size(nil) do
    {:ok, nil}
  end

  defp normalize_page_size(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp normalize_page_size(_value) do
    {:error, %Error{code: :bad_request, message: "pageSize must be a positive integer"}}
  end

  defp callback_cursor_start_index(_tasks, nil) do
    {:ok, 0}
  end

  defp callback_cursor_start_index(tasks, cursor) when is_binary(cursor) and cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"afterTaskId" => task_id}} <- JSON.decode(decoded),
         index when is_integer(index) <- Enum.find_index(tasks, &(&1.id == task_id)) do
      {:ok, index + 1}
    else
      _other ->
        {:error, %Error{code: :bad_request, message: "invalid cursor"}}
    end
  end

  defp callback_cursor_start_index(_tasks, _cursor) do
    {:error, %Error{code: :bad_request, message: "invalid cursor"}}
  end

  defp encode_callback_task_cursor(task_id) do
    %{"afterTaskId" => task_id}
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp new_callback_task(task_id, method, submitted_at, ttl_ms) do
    %{
      id: task_id,
      method: method,
      direction: :server_to_client,
      component_type: :callback_task,
      target: method,
      status: :working,
      poll_interval_ms: 500,
      ttl_ms: ttl_ms,
      submitted_at: submitted_at,
      updated_at: submitted_at,
      completed_at: nil,
      expires_at: nil,
      result: nil,
      error: nil,
      pid: nil,
      monitor_ref: nil
    }
  end

  defp callback_task_create_result(task) do
    %BackgroundTask{
      server_name: "FastestMCP.Client",
      task_id: task.id,
      component_type: :tool,
      target: task.method,
      poll_interval_ms: task.poll_interval_ms,
      ttl_ms: task.ttl_ms,
      submitted_at: task.submitted_at
    }
    |> TaskWire.create_task_result()
  end

  defp maybe_post_callback_task_notification(
         %{transport: %{type: :streamable_http}} = state,
         task
       ) do
    payload = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tasks/status",
      "params" => TaskWire.task(task, mask_error_details: true)
    }

    snapshot = FastestMCP.Client.TransportSnapshot.new(state)

    FastestMCP.Client.Workers.start(state.worker_supervisor, fn ->
      _ = do_post_client_response(snapshot, payload, [])
    end)

    :ok
  end

  defp maybe_post_callback_task_notification(_state, _task) do
    :ok
  end

  defp parse_task_request(params) when is_map(params) do
    case fetch_task_request(params) do
      :error ->
        {false, 60000}

      {:ok, %{} = task_value} ->
        {true, normalize_callback_task_ttl(Map.get(task_value, "ttl", Map.get(task_value, :ttl)))}

      {:ok, task_value} ->
        raise ArgumentError, "task metadata must be an object, got #{inspect(task_value)}"
    end
  end

  defp fetch_task_request(params) do
    cond do
      Map.has_key?(params, "task") -> Map.fetch(params, "task")
      Map.has_key?(params, :task) -> Map.fetch(params, :task)
      true -> :error
    end
  end

  defp safe_parse_task_request(params) do
    {:ok, parse_task_request(params)}
  rescue
    error in ArgumentError ->
      {:error, %Error{code: :bad_request, message: Exception.message(error)}}
  end

  defp normalize_callback_task_ttl(nil) do
    60000
  end

  defp normalize_callback_task_ttl(ttl) do
    Duration.positive_milliseconds!(ttl, "task ttl")
  end

  defp fetch_required_param(params, key, method) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{code: :bad_request, message: "#{method} requires #{key}"}}
    end
  end

  defp post_invalid_task_error(state, id, task_id, opts) do
    with :ok <-
           post_client_response(
             state,
             id,
             {:error,
              %Error{
                code: :bad_request,
                message: "Invalid taskId: #{to_string(task_id)} not found"
              }},
             opts
           ) do
      {:ok, state}
    end
  end

  defp missing_callback_handler_message("sampling/createMessage") do
    "client has no sampling handler"
  end

  defp missing_callback_handler_message("elicitation/create") do
    "client has no elicitation handler"
  end

  defp missing_callback_handler_message(method) do
    "client has no handler for #{inspect(method)}"
  end

  defp register_callback_result_waiter(state, task_id, id, opts) do
    waiter_ref = make_ref()

    update_in(state.callbacks.callback_result_waiters, fn waiters ->
      Map.update(waiters, task_id, %{waiter_ref => %{id: id, opts: opts}}, fn existing ->
        Map.put(existing, waiter_ref, %{id: id, opts: opts})
      end)
    end)
  end

  defp resolve_callback_result_waiters(state, task) do
    response = callback_task_result_response(task)

    case Map.pop(state.callbacks.callback_result_waiters, task.id) do
      {nil, callback_result_waiters} ->
        %{
          state
          | callbacks: %{state.callbacks | callback_result_waiters: callback_result_waiters}
        }

      {waiters, callback_result_waiters} ->
        next_state = %{
          state
          | callbacks: %{state.callbacks | callback_result_waiters: callback_result_waiters}
        }

        Enum.each(waiters, fn {_waiter_ref, waiter} ->
          post_client_response_async(next_state, waiter.id, response, waiter.opts)
        end)

        next_state
    end
  end

  defp callback_task_result_response(%{id: task_id, status: :completed, result: result}) do
    {:ok, TaskWire.task_result(result, task_id)}
  end

  defp callback_task_result_response(%{id: task_id, status: :failed} = task) do
    error =
      task.error ||
        %Error{code: :internal_error, message: "client callback task failed"}

    {:error,
     error
     |> Error.with_meta(TaskWire.related_task_meta(task_id))
     |> ErrorExposure.public_error(mask_error_details: true, task: task)}
  end

  defp callback_task_result_response(%{id: task_id, status: :cancelled}) do
    {:error,
     Error.with_meta(
       %Error{code: :cancelled, message: "background task was cancelled"},
       TaskWire.related_task_meta(task_id)
     )}
  end

  def dispatch_notification_on_owner(message, state) do
    if self() == state.client_pid do
      route_server_notification(message, state)
    else
      send(state.client_pid, {:server_notification, message})
      state
    end
  end

  def route_server_notification(message, state) do
    subscription_id =
      get_in(message, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"])

    if is_binary(subscription_id) or is_integer(subscription_id) do
      case find_outbound_request_by_id(state, subscription_id) do
        {ref, %{method: "subscriptions/listen", protocol_version: "2026-07-28"} = entry} ->
          route_modern_subscription_notification(state, ref, entry, message)

        _unknown_or_non_subscription_request ->
          record_subscription_protocol_error(:unknown_subscription_id, subscription_id)
          state
      end
    else
      dispatch_notification(message, state)
    end
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: false} = entry,
         %{
           "method" => "notifications/subscriptions/acknowledged",
           "params" => %{"notifications" => accepted}
         } = message
       ) do
    requested = get_in(entry, [Access.key(:request_params), "notifications"]) || %{}

    case Subscriptions.acknowledged_subset(requested, accepted) do
      {:ok, accepted} ->
        compiled_filter = Subscriptions.compile_filter(accepted)
        maybe_invoke_notification_handler(entry.notification_handler, message)

        state
        |> put_in(
          [Access.key(:pending), Access.key(:in_flight), ref, :subscription_acknowledged?],
          true
        )
        |> put_in(
          [Access.key(:pending), Access.key(:in_flight), ref, :acknowledged_subscription_filter],
          compiled_filter
        )
        |> put_in(
          [Access.key(:pending), Access.key(:in_flight), ref, :subscription_reconnect_attempt],
          0
        )
        |> then(&dispatch_notification(message, &1))

      {:error, reason} ->
        reject_modern_subscription_notification(state, ref, entry, reason)
    end
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: false} = entry,
         _message
       ) do
    reject_modern_subscription_notification(
      state,
      ref,
      entry,
      "subscription notification arrived before acknowledgement"
    )
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: true} = entry,
         %{"method" => "notifications/subscriptions/acknowledged"}
       ) do
    reject_modern_subscription_notification(
      state,
      ref,
      entry,
      "subscription acknowledgement was sent more than once"
    )
  end

  defp route_modern_subscription_notification(state, ref, entry, message) do
    if Subscriptions.notification_allowed?(
         Map.fetch!(entry, :acknowledged_subscription_filter),
         message
       ) do
      maybe_invoke_notification_handler(entry.notification_handler, message)
      dispatch_notification(message, state)
    else
      reject_modern_subscription_notification(
        state,
        ref,
        entry,
        "subscription notification is outside the acknowledged filter"
      )
    end
  end

  defp reject_modern_subscription_notification(state, ref, entry, reason) do
    error = %Error{
      code: :invalid_request,
      message: "invalid subscriptions/listen stream",
      details: %{reason: reason}
    }

    record_subscription_protocol_error(:invalid_stream, entry.request_id)
    _ = maybe_send_outbound_cancellation(state, entry, reason)

    case state.transport.type do
      :streamable_http ->
        complete_http_request(state, ref, {:error, error})

      type when type in [:stdio, :in_process] ->
        FastestMCP.Client.HTTP.finish_stdio_request(state, ref, {:error, error})
    end
  end

  defp record_subscription_protocol_error(reason, subscription_id) do
    :telemetry.execute(
      [:fastest_mcp, :client, :subscription, :protocol_error],
      %{count: 1},
      %{reason: reason, subscription_id: subscription_id}
    )
  end

  defp dispatch_notification(
         %{"method" => method},
         %{lifecycle: %{lifecycle_state: lifecycle_state}} = state
       )
       when lifecycle_state != :initialized and
              not (lifecycle_state == :initializing and method == "notifications/message") do
    state
  end

  defp dispatch_notification(
         %{"method" => "notifications/cancelled", "params" => params},
         state
       ) do
    request_id = Map.get(params, "requestId")

    case find_outbound_request_by_id(state, request_id) do
      {ref, entry} when entry.method == "subscriptions/listen" ->
        complete_cancelled_subscription(state, ref, entry)

      _other ->
        cancel_inbound_callback(state, request_id)
    end
  end

  defp dispatch_notification(
         %{"method" => "notifications/elicitation/complete", "params" => params} = message,
         state
       ) do
    elicitation_id = Map.get(params, "elicitationId")

    case Map.pop(state.callbacks.pending_url_elicitations, elicitation_id) do
      {nil, _pending} ->
        state

      {elicitation, pending} ->
        maybe_invoke_notification_handler(state.elicitation_complete_handler, elicitation)
        maybe_invoke_notification_handler(state.notification_handler, message)
        %{state | callbacks: %{state.callbacks | pending_url_elicitations: pending}}
    end
  end

  defp dispatch_notification(%{"method" => "notifications/message", "params" => params}, state) do
    maybe_invoke_notification_handler(state.log_handler, params)

    maybe_invoke_notification_handler(state.notification_handler, %{
      "method" => "notifications/message",
      "params" => params
    })

    state
  end

  defp dispatch_notification(
         %{"method" => "notifications/progress", "params" => %{"progress" => progress} = params},
         state
       ) do
    total = FastestMCP.Client.CallbackProgress.progress_total(params)

    case find_progress_target(state, Map.get(params, "progressToken")) do
      {:request, ref, request} ->
        dispatch_progress_notification(state, {:request, ref}, request, params, progress, total)

      {:task, task_id, task} ->
        dispatch_progress_notification(state, {:task, task_id}, task, params, progress, total)

      :error ->
        state
    end
  end

  defp dispatch_notification(
         %{"method" => method, "params" => params} = message,
         state
       )
       when method in ["notifications/tasks/status", "notifications/tasks"] do
    state =
      update_task_status(state, FastestMCP.Client.Execution.task_id_from_status(params), params)

    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  defp dispatch_notification(%{"method" => "notifications/tools/list_changed"} = message, state) do
    maybe_invoke_notification_handler(state.notification_handler, message)

    state
    |> invalidate_client_caches(:list_changed)
  end

  defp dispatch_notification(%{"method" => method} = message, state)
       when method in [
              "notifications/prompts/list_changed",
              "notifications/resources/list_changed",
              "notifications/resources/updated"
            ] do
    maybe_invoke_notification_handler(state.notification_handler, message)
    invalidate_response_cache(state)
  end

  defp dispatch_notification(message, state) do
    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  def find_outbound_request_by_id(state, request_id) do
    Enum.find(state.pending.in_flight, fn {_ref, entry} -> entry.request_id == request_id end)
  end

  defp complete_cancelled_subscription(state, ref, entry) do
    FastestMCP.Client.RequestOwnership.cancel_timer(entry.timer_ref)
    FastestMCP.Client.RequestOwnership.cancel_timer(Map.get(entry, :reconnect_timer_ref))
    FastestMCP.Client.HTTP.cancel_http_request(Map.get(entry, :request_ref))

    if is_pid(entry[:worker_pid]) do
      Process.exit(entry.worker_pid, :kill)
    end

    if entry[:worker_ref] do
      Process.demonitor(entry.worker_ref, [:flush])
    end

    FastestMCP.Client.RequestOwnership.reply_request_entry(
      entry,
      {:ok,
       %{
         "resultType" => "complete",
         "_meta" => %{"io.modelcontextprotocol/subscriptionId" => entry.request_id}
       }}
    )

    %{
      state
      | pending: %{
          state.pending
          | in_flight: Map.delete(state.pending.in_flight, ref),
            worker_refs:
              FastestMCP.Client.RequestOwnership.drop_worker_ref(
                state.pending.worker_refs,
                entry[:worker_ref]
              ),
            request_owner_refs:
              FastestMCP.Client.RequestOwnership.drop_owner_ref(
                state.pending.request_owner_refs,
                entry.owner_ref
              )
        },
        stdio: %{
          state.stdio
          | pending_stdio_refs: Map.delete(state.stdio.pending_stdio_refs, entry.request_id)
        }
    }
  end

  defp dispatch_progress_notification(state, target, owner, params, progress, total) do
    case FastestMCP.Client.CallbackProgress.validate_progress_update(
           progress,
           owner[:last_progress],
           total,
           owner[:progress_total]
         ) do
      {:ok, progress_total} ->
        maybe_invoke_notification_handler(owner[:progress_handler], params)
        maybe_invoke_notification_handler(state.progress_handler, params)

        maybe_invoke_notification_handler(state.notification_handler, %{
          "method" => "notifications/progress",
          "params" => params
        })

        store_peer_progress(state, target, progress, progress_total)

      {:error, _reason} ->
        state
    end
  end

  defp find_progress_target(_state, nil) do
    :error
  end

  defp find_progress_target(state, progress_token) do
    case Enum.find(state.pending.in_flight, fn {_ref, entry} ->
           entry.progress_token == progress_token
         end) do
      {ref, request} ->
        {:request, ref, request}

      nil ->
        case Enum.find(state.tasks.task_registry, fn {_task_id, task} ->
               task[:progress_token] == progress_token
             end) do
          {task_id, task} -> {:task, task_id, task}
          nil -> :error
        end
    end
  end

  defp store_peer_progress(state, {:request, ref}, progress, progress_total) do
    state
    |> put_in([Access.key(:pending), Access.key(:in_flight), ref, :last_progress], progress)
    |> put_in(
      [Access.key(:pending), Access.key(:in_flight), ref, :progress_total],
      progress_total
    )
  end

  defp store_peer_progress(state, {:task, task_id}, progress, progress_total) do
    state
    |> put_in([Access.key(:tasks), Access.key(:task_registry), task_id, :last_progress], progress)
    |> put_in(
      [Access.key(:tasks), Access.key(:task_registry), task_id, :progress_total],
      progress_total
    )
  end

  defp maybe_invoke_notification_handler(nil, _payload) do
    :ok
  end

  defp maybe_invoke_notification_handler(handler, payload) do
    cond do
      is_function(handler, 1) -> handler.(payload)
      is_function(handler, 0) -> handler.()
      true -> :ok
    end
  rescue
    _error ->
      :ok
  catch
    _kind, _reason ->
      :ok
  end

  def ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok
    end
  end

  def decode_jsonrpc_response_payload(
        payload,
        expected_id,
        method,
        task_augmented,
        protocol_version
      ) do
    case JSONRPC.decode(payload, direction: :server_to_client, protocol_version: protocol_version) do
      {:ok, {:response, response_id, response}} ->
        FastestMCP.Client.HTTP.decode_jsonrpc_response(
          response_id,
          response,
          expected_id,
          method,
          task_augmented,
          protocol_version
        )

      {:ok, {:request, _method, _params, _request_id}} ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "expected a JSON-RPC response",
           details: %{payload: payload}
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def normalize_response_result(
        {:initialize, supported_version},
        %{"protocolVersion" => protocol_version} = result
      ) do
    if protocol_version == supported_version do
      {:ok, result}
    else
      unsupported_initialize_protocol(protocol_version, supported_version)
    end
  end

  def normalize_response_result({:initialize, supported_version}, result) do
    protocol_version =
      if is_map(result) do
        Map.get(result, "protocolVersion")
      else
        nil
      end

    unsupported_initialize_protocol(protocol_version, supported_version)
  end

  def normalize_response_result(normalizer, result) do
    {:ok, FastestMCP.Client.Codec.normalize_response(normalizer, result)}
  end

  def response_cache_hint(%{
        "resultType" => "complete",
        "ttlMs" => ttl_ms,
        "cacheScope" => cache_scope
      })
      when is_integer(ttl_ms) and ttl_ms > 0 and cache_scope in ["private", "public"] do
    %{ttl_ms: ttl_ms, cache_scope: cache_scope}
  end

  def response_cache_hint(_result) do
    nil
  end

  def maybe_store_response_cache(
        state,
        %{response_cache_key: key, response_cache_mode: mode},
        {:ok, result},
        %{ttl_ms: ttl_ms}
      )
      when not is_nil(key) and mode in [:use, :refresh] do
    %{
      state
      | catalog: %{
          state.catalog
          | response_cache: ResponseCache.put(state.catalog.response_cache, key, result, ttl_ms)
        }
    }
  end

  def maybe_store_response_cache(state, _entry, _reply, _hint) do
    state
  end

  defp unsupported_initialize_protocol(protocol_version, supported_version) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "server returned an unsupported protocolVersion #{inspect(protocol_version)}",
       details: %{supported: [supported_version]}
     }}
  end

  defp validate_protocol_options(opts) do
    cond do
      Keyword.has_key?(opts, :supported_protocol_versions) ->
        {:error,
         %Error{
           code: :invalid_params,
           message:
             "supported_protocol_versions is not configurable; use protocol_version: :auto or an exact supported version"
         }}

      Keyword.get(opts, :protocol_version, :auto) not in [:auto | Protocol.supported_versions()] ->
        {:error,
         %Error{
           code: :invalid_params,
           message:
             "protocol_version must be :auto or one of #{inspect(Protocol.supported_versions())}"
         }}

      true ->
        :ok
    end
  end

  def maybe_put_oauth_authorization(headers, %{oauth: %{pid: pid, resource: resource}}) do
    case OAuth.authorization_header(pid, resource) do
      {:ok, authorization} -> Map.put(headers, "authorization", authorization)
      :none -> Map.delete(headers, "authorization")
      {:error, %OAuthError{}} -> Map.delete(headers, "authorization")
    end
  end

  def maybe_put_oauth_authorization(headers, _state) do
    headers
  end

  defp apply_http_response_metadata(
         {:ok, result, headers, cache_hint},
         state,
         %{lifecycle: %{session_generation: generation}}
       )
       when generation == state.lifecycle.session_generation do
    session_id =
      FastestMCP.Client.Codec.response_header(headers, "mcp-session-id") || state.session_id

    {{:ok, result}, %{state | session_id: session_id}, cache_hint}
  end

  defp apply_http_response_metadata(
         {:ok, result, _headers, cache_hint},
         state,
         _stale_entry
       ) do
    {{:ok, result}, state, cache_hint}
  end

  defp apply_http_response_metadata(result, state, _entry) do
    {result, state, nil}
  end
end
