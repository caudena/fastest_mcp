defmodule FastestMCP.Client.Connection.Dispatcher do
  @moduledoc false
  # Runs user notification handlers outside the connection process, one at a
  # time in arrival order. A handler that raises, throws or exits is logged
  # and the next one runs.

  require Logger

  alias FastestMCP.Client.Workers

  def start(supervisor), do: Workers.start!(supervisor, &loop/0)

  def dispatch(_dispatcher, nil, _payload), do: :ok

  def dispatch(dispatcher, handler, payload) do
    send(dispatcher, {:dispatch, handler, payload})
    :ok
  end

  defp loop do
    receive do
      {:dispatch, handler, payload} ->
        invoke(handler, payload)
        loop()
    end
  end

  defp invoke(handler, payload) do
    cond do
      is_function(handler, 1) -> handler.(payload)
      is_function(handler, 0) -> handler.()
      true -> :ok
    end
  catch
    kind, reason ->
      Logger.error(
        "MCP client notification handler failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end
end
