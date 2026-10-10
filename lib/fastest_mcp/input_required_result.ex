defmodule FastestMCP.InputRequiredResult do
  @moduledoc """
  A handler result that asks the client for input before the request can
  finish: a multi-round-trip request of MCP `2026-07-28`.

  The helpers (`FastestMCP.Interact`, `FastestMCP.Sampling`,
  `FastestMCP.Context.elicit/4`, `FastestMCP.Context.sample/3`, and
  `FastestMCP.Context.list_roots/2`) build these results for you on
  `2026-07-28`, one question per round. Return one yourself to ask several
  things in one round, or to choose the keys and the request state; see
  [Multi-round-trip requests](sampling-and-elicitation.md#multi-round-trip-requests).

  The keys in `input_requests` are yours, and the client answers under the
  same keys in `inputResponses`. `request_state` is opaque to FastestMCP: if it
  carries authorization or business state, authenticate, expire, and bind it
  to the call yourself.
  """

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.Protocol

  @enforce_keys []
  defstruct input_requests: nil, request_state: nil, meta: nil, timeout_ms: 60_000

  @type t :: %__MODULE__{
          input_requests: %{optional(String.t()) => map()} | nil,
          request_state: String.t() | nil,
          meta: map() | nil,
          timeout_ms: pos_integer()
        }

  @doc """
  Builds an input-required result from MCP request maps, each with a
  `"method"` and `"params"`, by key.

  Options: `:request_state`, an opaque string the client sends back with its
  answers; `:meta`, the result's `_meta`; and `:timeout_ms`, how long a
  background task waits for the answers before it fails with `:timeout`
  (default 60 seconds). Without a task, the server doesn't wait: the client
  sends the request again with the answers.
  """
  def new(input_requests \\ nil, opts \\ []) do
    request_state = Keyword.get(opts, :request_state)
    input_requests = normalize_input_requests(input_requests)

    if is_nil(input_requests) and is_nil(request_state) do
      raise ArgumentError, "input_required result requires input_requests or request_state"
    end

    %__MODULE__{
      input_requests: input_requests,
      request_state: normalize_request_state(request_state),
      meta: normalize_meta(Keyword.get(opts, :meta)),
      timeout_ms: normalize_timeout(Keyword.get(opts, :timeout_ms, 60_000))
    }
  end

  @doc false
  def to_map(%__MODULE__{} = result) do
    %{"resultType" => "input_required"}
    |> maybe_put("inputRequests", result.input_requests)
    |> maybe_put("requestState", result.request_state)
    |> maybe_put("_meta", result.meta)
  end

  @doc false
  def validate_client_capabilities(%__MODULE__{} = result, client_capabilities) do
    missing =
      Protocol.missing_input_capabilities(
        client_capabilities,
        result.input_requests || %{}
      )

    if map_size(missing) == 0 do
      :ok
    else
      {:error,
       %Error{
         code: :missing_required_client_capability,
         message: "input_required requests capabilities the client did not advertise",
         details: %{jsonrpc_code: -32_021, requiredCapabilities: missing}
       }}
    end
  end

  defp normalize_input_requests(nil), do: nil

  defp normalize_input_requests(requests) when is_map(requests) and map_size(requests) > 0 do
    Map.new(requests, fn {key, request} ->
      {key, request} = {to_string(key), JSONValue.stringify_keys(request)}

      unless key != "" and match?(%{"method" => method} when is_binary(method), request) do
        raise ArgumentError,
              "each input request must have a non-empty key and an MCP method, got #{inspect({key, request})}"
      end

      {key, request}
    end)
  end

  defp normalize_input_requests(%{}), do: nil

  defp normalize_input_requests(other) do
    raise ArgumentError,
          "input_requests must be a map of MCP request objects, got #{inspect(other)}"
  end

  defp normalize_request_state(nil), do: nil
  defp normalize_request_state(value) when is_binary(value), do: value

  defp normalize_request_state(other) do
    raise ArgumentError, "request_state must be an opaque string, got #{inspect(other)}"
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(other) do
    raise ArgumentError, "timeout_ms must be a positive integer, got #{inspect(other)}"
  end

  defp normalize_meta(nil), do: nil
  defp normalize_meta(value) when is_map(value), do: JSONValue.stringify_keys(value)

  defp normalize_meta(other) do
    raise ArgumentError, "input-required metadata must be a map, got #{inspect(other)}"
  end
end
