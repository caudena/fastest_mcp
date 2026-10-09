defmodule FastestMCP.Notifications do
  @moduledoc false
  # The notifications a listener gets for a server event, as JSON-RPC
  # notification envelopes. A listener is a map of what it follows:
  #
  #   * `:session_id` - the session it belongs to: list changes of other
  #     sessions do not reach it
  #   * `:tasks` - `{:session, session_id}` for the tasks of a session, or
  #     `{:ids, task_ids, owner}` for tasks by id that `owner` owns
  #   * `:families` - the component families whose list changes it gets
  #   * `:resource_uris` - the resources whose updates it gets

  alias FastestMCP.Protocol

  @list_changed %{
    tools: "notifications/tools/list_changed",
    resources: "notifications/resources/list_changed",
    prompts: "notifications/prompts/list_changed"
  }
  @filter_families %{
    "toolsListChanged" => :tools,
    "resourcesListChanged" => :resources,
    "promptsListChanged" => :prompts
  }

  # The listener of a legacy session with its negotiated server capabilities.
  def session_listener(session_id, capabilities, resource_uris) do
    %{
      session_id: session_id,
      tasks: if(Protocol.capability?(capabilities, ["tasks"]), do: {:session, session_id}),
      families:
        Enum.filter(Map.keys(@list_changed), fn family ->
          key = Atom.to_string(family)

          Protocol.capability?(capabilities, [key]) and
            Protocol.capability_flag?(capabilities, [key, "listChanged"])
        end),
      resource_uris:
        if(Protocol.capability?(capabilities, ["resources", "subscribe"]),
          do: resource_uris,
          else: []
        )
    }
  end

  # The listener of an MCP 2026 subscription with its accepted filter.
  def subscription_listener(filter, owner) do
    %{
      tasks: {:ids, MapSet.new(Map.get(filter, "taskIds", [])), owner},
      families: for({key, family} <- @filter_families, filter[key] == true, do: family),
      resource_uris: MapSet.new(Map.get(filter, "resourceSubscriptions", []))
    }
  end

  # The notifications `listener` gets for an event, whose metadata has atom keys.
  def notifications([:notifications, :tasks, :status], metadata, listener) do
    notification = metadata[:notification]

    case Map.get(listener, :tasks) do
      {:session, session_id} ->
        if is_binary(session_id) and metadata[:session_id] == session_id,
          do: [notification],
          else: []

      {:ids, task_ids, owner} ->
        task_id = metadata[:task_id]

        if is_binary(task_id) and task_id in task_ids and metadata[:owner_fingerprint] == owner,
          do: [notification("notifications/tasks", notification["params"])],
          else: []

      nil ->
        []
    end
  end

  def notifications([:components, :changed], metadata, listener) do
    scope = Map.get(listener, :session_id)
    session_id = metadata[:session_id]

    if is_nil(scope) or is_nil(session_id) or to_string(session_id) == scope do
      families = Map.get(listener, :families, [])

      for family <- metadata |> Map.get(:families) |> List.wrap() |> Enum.map(&family/1),
          family in families,
          do: %{"jsonrpc" => "2.0", "method" => Map.fetch!(@list_changed, family)}
    else
      []
    end
  end

  def notifications([:resources, :updated], metadata, listener) do
    uri = metadata[:uri]

    if is_binary(uri) and uri in Map.get(listener, :resource_uris, []),
      do: [notification("notifications/resources/updated", %{"uri" => uri})],
      else: []
  end

  def notifications(_event_suffix, _metadata, _listener), do: []

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp family(family) when family in [:tools, :resources, :prompts], do: family
  defp family("tools"), do: :tools
  defp family("resources"), do: :resources
  defp family("prompts"), do: :prompts
  defp family(_family), do: nil
end
