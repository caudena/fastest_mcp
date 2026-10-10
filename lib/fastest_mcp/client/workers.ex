defmodule FastestMCP.Client.Workers do
  @moduledoc false
  alias FastestMCP.Error

  def start!(supervisor, fun) do
    case Task.Supervisor.start_child(supervisor, fun, restart: :temporary) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "unable to start client worker",
          details: %{reason: inspect(reason)}
    end
  end
end
