defmodule FastestMCP.Client.Spec do
  @moduledoc false
  # One outbound request, built in the caller from its method, params,
  # normalizer and operation options. `trace` is the client span the request
  # belongs to: the connection annotates it, and ends it when `end_trace?`
  # (an asynchronous request that owns its span). `trace_context` is
  # propagated in the request's `_meta`. The connection sets the protocol
  # version when the request starts. The owner of an `owns_task?` request owns
  # the task it creates: the connection cancels the task when the owner exits
  # before disowning it.

  alias FastestMCP.Client.Auth
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Telemetry

  @default_timeout_ms 5_000

  @enforce_keys [:method, :params, :normalizer, :deadline]
  defstruct [
    :method,
    :params,
    :normalizer,
    :deadline,
    :protocol_version,
    :progress_handler,
    :on_notification,
    :trace,
    :trace_context,
    end_trace?: false,
    owns_task?: false,
    cache: :use,
    auth: [],
    http_parameter_headers: %{}
  ]

  @type t :: %__MODULE__{}

  # The deadline is `timeout_ms` from now, capped by an operation `deadline`.
  def new(method, params, normalizer, opts, trace) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    traced(
      %__MODULE__{
        method: method,
        params: scoped_progress_token(params, opts[:progress_handler]),
        normalizer: normalizer,
        deadline: opts |> Deadline.from_options(timeout) |> Deadline.cap(timeout),
        progress_handler: opts[:progress_handler],
        on_notification: opts[:on_notification],
        cache: Keyword.get(opts, :cache, :use),
        auth: Auth.options(opts),
        http_parameter_headers: Keyword.get(opts, :http_parameter_headers, %{})
      },
      trace
    )
  end

  # Without a span, a request propagates the caller's trace context.
  def traced(spec, nil), do: %{spec | trace: nil, trace_context: Telemetry.current_context()}
  def traced(spec, trace), do: %{spec | trace: trace, trace_context: trace.context}

  def check(%__MODULE__{cache: cache, progress_handler: handler}) do
    cond do
      cache not in [:use, :refresh, :bypass] ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "cache must be :use, :refresh, or :bypass",
           details: %{cache: inspect(cache)}
         }}

      not (is_nil(handler) or is_function(handler, 0) or is_function(handler, 1)) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "progress_handler must be a zero- or one-arity function"
         }}

      true ->
        :ok
    end
  end

  def progress_token(%__MODULE__{params: params}), do: get_in(params, ["_meta", "progressToken"])

  def progress_bearing?(params), do: match?(%{"_meta" => %{"progressToken" => _}}, params)

  # A request-scoped progress handler needs a token to route progress by.
  defp scoped_progress_token(params, nil), do: params

  defp scoped_progress_token(params, _handler) do
    if progress_bearing?(params) do
      params
    else
      token =
        "fastestmcp-progress-" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic]))

      Map.update(params, "_meta", %{"progressToken" => token}, fn meta ->
        meta |> Map.new() |> Map.put("progressToken", token)
      end)
    end
  end
end
