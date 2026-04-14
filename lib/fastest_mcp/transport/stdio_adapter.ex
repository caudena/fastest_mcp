defmodule FastestMCP.Transport.StdioAdapter do
  @moduledoc """
  Adapter that decodes and encodes stdio payloads.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  @behaviour FastestMCP.Transport.Adapter

  alias FastestMCP.Error
  alias FastestMCP.Transport.Request

  @impl true
  @doc "Decodes an external payload into the normalized request shape."
  def decode(%{"method" => method} = request) when is_binary(method) do
    params = request |> Map.get("params", %{}) |> Map.new()
    {task_request, task_ttl_ms} = parse_task(params)

    {:ok,
     %Request{
       method: method,
       transport: :stdio,
       session_id: params["session_id"],
       task_request: task_request,
       task_ttl_ms: task_ttl_ms,
       payload: params,
       request_metadata: %{
         method: method,
         session_id: params["session_id"],
         session_id_provided: not is_nil(params["session_id"])
       },
       auth_input: stdio_auth_input(params)
     }}
  end

  def decode(_request) do
    {:error, %Error{code: :bad_request, message: "stdio request must include method"}}
  end

  @impl true
  @doc "Encodes a successful transport response."
  def encode_success(_request, payload) do
    %{"ok" => true, "result" => json_value(payload)}
  end

  @impl true
  @doc "Encodes an error transport response."
  def encode_error(%Error{} = error) do
    %{
      "ok" => false,
      "error" => %{
        "code" => Atom.to_string(error.code),
        "message" => error.message,
        "details" => json_value(error.details)
      }
    }
    |> maybe_put("_meta", if(is_map(error.meta), do: json_value(error.meta)))
  end

  defp stdio_auth_input(params) do
    params
    |> Map.get("auth_input", %{})
    |> Map.new()
    |> maybe_put("token", params["auth_token"])
    |> maybe_put("authorization", params["authorization"])
  end

  defp parse_task(params) do
    meta_task =
      params
      |> Map.get("_meta", %{})
      |> Map.get("task")

    task_value = meta_task || params["task"]

    cond do
      task_value in [nil, false] ->
        {false, nil}

      task_value == true ->
        {true, nil}

      is_map(task_value) ->
        {true, normalize_ttl(Map.get(task_value, "ttl", Map.get(task_value, :ttl)))}

      true ->
        raise ArgumentError, "task metadata must be boolean or a map, got #{inspect(task_value)}"
    end
  end

  defp normalize_ttl(nil), do: nil
  defp normalize_ttl(value) when is_integer(value) and value > 0, do: value

  defp normalize_ttl(value),
    do: raise(ArgumentError, "task ttl must be a positive integer, got #{inspect(value)}")

  defp json_value(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
