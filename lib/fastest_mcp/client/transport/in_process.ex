defmodule FastestMCP.Client.Transport.InProcess do
  @moduledoc false

  @behaviour FastestMCP.Client.Transport

  alias FastestMCP.Client.Transport.InProcess.ConnectionSupervisor
  alias FastestMCP.Client.Transport.InProcess.Coordinator
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime

  @impl true
  def open(transport, owner) do
    connection_id = make_ref()

    with {:ok, _runtime} <- ServerRuntime.fetch(transport.server_name),
         {:ok, supervisor} <-
           ConnectionSupervisor.start_link(
             owner: owner,
             server_name: transport.server_name,
             connection_id: connection_id
           ) do
      case ConnectionSupervisor.coordinator(supervisor) do
        {:ok, coordinator} ->
          {:ok,
           Map.merge(transport, %{
             connection_id: connection_id,
             supervisor: supervisor,
             coordinator: coordinator
           })}

        {:error, reason} ->
          Supervisor.stop(supervisor, :normal)
          {:error, reason}
      end
    else
      {:error, :not_found} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "in-process server is not running",
           details: %{server_name: transport.server_name}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def connected?(%{coordinator: coordinator}) when is_pid(coordinator),
    do: Process.alive?(coordinator)

  def connected?(_transport), do: false

  @impl true
  def send_line(%{coordinator: coordinator}, line, auth_input) when is_pid(coordinator) do
    Coordinator.send_line(coordinator, line, auth_input)
  catch
    :exit, _reason -> {:error, :closed}
  end

  def send_line(_transport, _line, _auth_input), do: {:error, :closed}

  @impl true
  def close(%{coordinator: coordinator, supervisor: supervisor}) do
    if is_pid(coordinator) and Process.alive?(coordinator), do: Coordinator.close(coordinator)
    if is_pid(supervisor) and Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def close(_transport), do: :ok
end
