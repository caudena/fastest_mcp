defmodule FastestMCP.Registry do
  @moduledoc false
  # Process names for running servers, server owners, sessions, and URL
  # elicitations, and the settings of client connections, backed by a
  # unique-key `Registry`. Entries disappear with their processes; lookups
  # also skip a process that has exited but whose entry the Registry has not
  # removed yet. Registry metadata holds per-server component visibility
  # rules, which are read on every request and written rarely.

  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  def via(key), do: {:via, Registry, {__MODULE__, key}}

  def lookup_server(server_name), do: whereis({:server, to_string(server_name)})
  def lookup_server_owner(server_name), do: whereis({:server_owner, to_string(server_name)})

  def lookup_runtime_supervisor(server_name),
    do: whereis({:runtime_supervisor, to_string(server_name)})

  def lookup_session(server_name, session_id),
    do: whereis({:session, to_string(server_name), to_string(session_id)})

  def register_url_elicitation(server_name, elicitation_id, session_id) do
    case Registry.register(
           __MODULE__,
           url_elicitation_key(server_name, elicitation_id),
           session_id
         ) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_exists}
    end
  end

  def unregister_url_elicitation(server_name, elicitation_id),
    do: Registry.unregister(__MODULE__, url_elicitation_key(server_name, elicitation_id))

  def lookup_url_elicitation(server_name, elicitation_id) do
    case Registry.lookup(__MODULE__, url_elicitation_key(server_name, elicitation_id)) do
      [{pid, session_id}] -> if Process.alive?(pid), do: {:ok, session_id, pid}, else: not_found()
      [] -> not_found()
    end
  end

  def publish_runtime(server_name, runtime) do
    {:ok, _owner} = Registry.register(__MODULE__, {:runtime, to_string(server_name)}, runtime)
    :ok
  end

  def lookup_runtime(server_name) do
    case Registry.lookup(__MODULE__, {:runtime, to_string(server_name)}) do
      [{pid, runtime}] -> if Process.alive?(pid), do: {:ok, runtime}, else: not_found()
      [] -> not_found()
    end
  end

  def register_component_index(server_name, table) do
    {:ok, _owner} =
      Registry.register(__MODULE__, {:component_index, to_string(server_name)}, table)

    :ok
  end

  def component_index(server_name) do
    case Registry.lookup(__MODULE__, {:component_index, to_string(server_name)}) do
      [{_pid, table}] -> {:ok, table}
      [] -> {:error, :not_found}
    end
  end

  # The settings a client connection publishes for the operations its callers
  # run, so that they need no call to the connection.
  def register_client(settings) do
    {:ok, _owner} = Registry.register(__MODULE__, {:client, self()}, settings)
    :ok
  end

  def client_settings(pid) do
    case Registry.lookup(__MODULE__, {:client, pid}) do
      [{^pid, settings}] -> if Process.alive?(pid), do: {:ok, settings}, else: not_found()
      [] -> not_found()
    end
  end

  def visibility_rules(server_name) do
    case Registry.meta(__MODULE__, {:visibility_rules, to_string(server_name)}) do
      {:ok, rules} -> rules
      :error -> []
    end
  end

  def put_visibility_rules(server_name, []),
    do: Registry.delete_meta(__MODULE__, {:visibility_rules, to_string(server_name)})

  def put_visibility_rules(server_name, rules),
    do: Registry.put_meta(__MODULE__, {:visibility_rules, to_string(server_name)}, rules)

  defp whereis(key) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _value}] -> if Process.alive?(pid), do: {:ok, pid}, else: not_found()
      [] -> not_found()
    end
  end

  defp not_found, do: {:error, :not_found}

  defp url_elicitation_key(server_name, elicitation_id),
    do: {:url_elicitation, to_string(server_name), elicitation_id}
end
