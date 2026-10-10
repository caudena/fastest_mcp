defmodule FastestMCP.Transport.Request do
  @moduledoc false
  # One request as a transport adapter decoded it. `Transport.Engine` resolves
  # its `protocol_version` and sets `profile` and the session `lifecycle`
  # before running it. Transports set the sink the request reports through:
  # `sink_ref`, the session sink of a legacy POST stream or a stdio
  # connection, or `stream_sink`, the `{pid, tag}` of a modern request stream.
  # `request_metadata` holds what only the transport knows (HTTP headers, the
  # stdio connection, the JSON-RPC envelope).

  import FastestMCP.Protocol.Version

  alias FastestMCP.Error
  alias FastestMCP.Transport.JSONRPC

  @derive {Inspect, except: [:auth_input, :auth_result, :transport_authorization]}
  defstruct [
    :method,
    :transport,
    :session_id,
    :request_id,
    :auth_result,
    :protocol_version,
    :transport_authorization,
    :progress_token,
    :log_level,
    :sink_ref,
    :stream_sink,
    :profile,
    :lifecycle,
    protocol: :native,
    session_id_provided?: false,
    task_request: false,
    task_ttl_ms: nil,
    payload: %{},
    request_metadata: %{},
    auth_input: %{}
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          transport: atom(),
          session_id: String.t() | nil,
          request_id: String.t() | integer() | nil,
          auth_result: FastestMCP.Auth.Result.t() | nil,
          protocol_version: String.t() | nil,
          transport_authorization: String.t() | nil,
          progress_token: String.t() | integer() | nil,
          log_level: String.t() | nil,
          sink_ref: reference() | nil,
          stream_sink: {pid(), term()} | nil,
          profile: FastestMCP.Protocol.profile() | nil,
          lifecycle: map() | nil,
          protocol: :native | :jsonrpc,
          session_id_provided?: boolean(),
          task_request: boolean(),
          task_ttl_ms: pos_integer() | nil,
          payload: map(),
          request_metadata: map(),
          auth_input: map()
        }

  # A decoded JSON-RPC message; a client response gets a transport method.
  def from_jsonrpc({:request, method, params, request_id}, envelope) do
    with {:ok, {task_request, task_ttl_ms}} <- JSONRPC.task_metadata(params) do
      meta = Map.get(params, "_meta") || %{}

      {:ok,
       %__MODULE__{
         method: method,
         protocol: :jsonrpc,
         request_id: request_id,
         protocol_version: meta["io.modelcontextprotocol/protocolVersion"],
         progress_token: meta["progressToken"],
         log_level: meta["io.modelcontextprotocol/logLevel"],
         task_request: task_request,
         task_ttl_ms: task_ttl_ms,
         payload: JSONRPC.sanitize_auth_metadata(params),
         request_metadata: %{jsonrpc_envelope: JSONRPC.sanitize_stored_envelope(envelope)}
       }}
    end
  end

  def from_jsonrpc({:response, request_id, payload}, envelope) do
    {:ok,
     %__MODULE__{
       method: "__transport/client_response__",
       protocol: :jsonrpc,
       request_id: request_id,
       payload: payload,
       request_metadata: %{jsonrpc_envelope: envelope}
     }}
  end

  def fetch_param(%__MODULE__{payload: payload, method: method}, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{code: :bad_request, message: "#{method} requires #{key}"}}
    end
  end

  # The client capabilities declared in the request metadata.
  def client_capabilities(%__MODULE__{payload: payload}),
    do: get_in(payload, ["_meta", "io.modelcontextprotocol/clientCapabilities"]) || %{}

  # The component version requested in `_meta.fastestmcp.version`.
  def component_version(%__MODULE__{payload: payload}) do
    case get_in(payload, ["_meta", "fastestmcp"]) do
      %{} = meta -> Map.get(meta, "version")
      _other -> nil
    end
  end

  # The session the client named explicitly, which task methods need.
  def explicit_session_id(%__MODULE__{session_id_provided?: true, session_id: session_id})
      when is_binary(session_id) and session_id != "",
      do: {:ok, session_id}

  def explicit_session_id(%__MODULE__{}), do: :error

  # Whether the client attempts the modern protocol, perhaps in a version the
  # server does not support.
  def modern_attempt?(%__MODULE__{protocol_version: version, payload: payload}) do
    is_modern(version) or
      is_binary(get_in(payload, ["_meta", "io.modelcontextprotocol/protocolVersion"]))
  end
end
