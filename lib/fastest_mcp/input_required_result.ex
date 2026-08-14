defmodule FastestMCP.InputRequiredResult do
  @moduledoc """
  Handler result for a modern MCP multi round-trip request (MRTR).

  The keys in `input_requests` are chosen by the application and are echoed by
  the client in `inputResponses`. `request_state` is deliberately opaque to
  FastestMCP: applications that place authorization or business state in it
  remain responsible for authenticating, expiring, and binding that value to
  the retried operation.
  """

  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.Protocol

  @enforce_keys []
  defstruct input_requests: nil, request_state: nil, meta: nil

  @type t :: %__MODULE__{
          input_requests: %{optional(String.t()) => map()} | nil,
          request_state: String.t() | nil,
          meta: map() | nil
        }

  @doc "Builds an input-required result from server-initiated MCP request objects."
  def new(input_requests \\ nil, opts \\ []) do
    request_state = Keyword.get(opts, :request_state)
    input_requests = normalize_input_requests(input_requests)

    if is_nil(input_requests) and is_nil(request_state) do
      raise ArgumentError, "input_required result requires input_requests or request_state"
    end

    %__MODULE__{
      input_requests: input_requests,
      request_state: normalize_request_state(request_state),
      meta: normalize_meta(Keyword.get(opts, :meta))
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
      key = to_string(key)

      unless key != "" and is_map(request) and is_binary(map_value(request, :method)) do
        raise ArgumentError,
              "each input request must have a non-empty key and an MCP method, got #{inspect({key, request})}"
      end

      {key, JSONValue.stringify_keys(request)}
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

  defp normalize_meta(nil), do: nil
  defp normalize_meta(value) when is_map(value), do: JSONValue.stringify_keys(value)

  defp normalize_meta(other) do
    raise ArgumentError, "input-required metadata must be a map, got #{inspect(other)}"
  end

  defp map_value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
