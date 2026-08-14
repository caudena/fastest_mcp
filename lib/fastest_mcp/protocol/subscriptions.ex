defmodule FastestMCP.Protocol.Subscriptions do
  @moduledoc false

  alias FastestMCP.Protocol

  @boolean_filter_keys ~w(toolsListChanged resourcesListChanged promptsListChanged)
  @list_filter_keys ~w(resourceSubscriptions taskIds)
  @known_filter_keys @boolean_filter_keys ++ @list_filter_keys

  @notification_filters %{
    "notifications/tools/list_changed" => "toolsListChanged",
    "notifications/resources/list_changed" => "resourcesListChanged",
    "notifications/prompts/list_changed" => "promptsListChanged"
  }

  @doc false
  def normalize_filter!(filter, opts \\ []) do
    case normalize_filter(filter, opts) do
      {:ok, normalized} -> normalized
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc false
  def normalize_filter(filter, opts \\ [])

  def normalize_filter(filter, opts) when is_map(filter) do
    reject_unknown? = Keyword.get(opts, :reject_unknown, false)
    filter = Map.new(filter, fn {key, value} -> {to_string(key), value} end)

    cond do
      reject_unknown? and Enum.any?(Map.keys(filter), &(&1 not in @known_filter_keys)) ->
        {:error, "subscription acknowledgement contains an unknown filter"}

      true ->
        filter
        |> Map.take(@known_filter_keys)
        |> Enum.reduce_while({:ok, %{}}, &normalize_filter_entry/2)
    end
  end

  def normalize_filter(_filter, _opts), do: {:error, "subscription filter must be an object"}

  @doc false
  def narrow(requested, capabilities, resource_uris, task_ids) do
    requested = normalize_filter!(requested)
    resource_uris = MapSet.new(resource_uris)
    task_ids = MapSet.new(task_ids)

    Enum.reduce(requested, %{}, fn
      {"toolsListChanged", true}, accepted ->
        maybe_accept_flag(accepted, capabilities, ["tools", "listChanged"], "toolsListChanged")

      {"resourcesListChanged", true}, accepted ->
        maybe_accept_flag(
          accepted,
          capabilities,
          ["resources", "listChanged"],
          "resourcesListChanged"
        )

      {"promptsListChanged", true}, accepted ->
        maybe_accept_flag(
          accepted,
          capabilities,
          ["prompts", "listChanged"],
          "promptsListChanged"
        )

      {"resourceSubscriptions", uris}, accepted ->
        Map.put(
          accepted,
          "resourceSubscriptions",
          Enum.filter(uris, &MapSet.member?(resource_uris, &1))
        )

      {"taskIds", ids}, accepted ->
        Map.put(accepted, "taskIds", Enum.filter(ids, &MapSet.member?(task_ids, &1)))
    end)
  end

  @doc false
  def acknowledged_subset(requested, accepted) do
    with {:ok, requested} <- normalize_filter(requested),
         {:ok, accepted} <- normalize_filter(accepted, reject_unknown: true),
         true <- subset?(requested, accepted) do
      {:ok, accepted}
    else
      false -> {:error, "subscription acknowledgement exceeds the requested filter"}
      {:error, message} -> {:error, message}
    end
  end

  @doc false
  def compile_filter(filter) do
    filter = normalize_filter!(filter)

    %{
      filter: filter,
      resource_uris: MapSet.new(Map.get(filter, "resourceSubscriptions", [])),
      task_ids: MapSet.new(Map.get(filter, "taskIds", []))
    }
  end

  @doc false
  def notification_allowed?(compiled, %{"method" => method, "params" => params})
      when is_map(params) do
    filter = Map.fetch!(compiled, :filter)

    case method do
      "notifications/resources/updated" ->
        MapSet.member?(compiled.resource_uris, Map.get(params, "uri"))

      "notifications/tasks" ->
        MapSet.member?(compiled.task_ids, Map.get(params, "taskId"))

      "notifications/cancelled" ->
        true

      method when is_map_key(@notification_filters, method) ->
        Map.get(filter, Map.fetch!(@notification_filters, method)) == true

      _other ->
        false
    end
  end

  def notification_allowed?(_compiled, _notification), do: false

  defp normalize_filter_entry({key, true}, {:ok, acc}) when key in @boolean_filter_keys,
    do: {:cont, {:ok, Map.put(acc, key, true)}}

  defp normalize_filter_entry({key, false}, {:ok, acc}) when key in @boolean_filter_keys,
    do: {:cont, {:ok, acc}}

  defp normalize_filter_entry({key, values}, {:ok, acc})
       when key in @list_filter_keys and is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:cont, {:ok, Map.put(acc, key, Enum.uniq(values))}}
    else
      {:halt, {:error, "subscription filter #{key} must contain only strings"}}
    end
  end

  defp normalize_filter_entry({key, _value}, {:ok, _acc}) when key in @boolean_filter_keys,
    do: {:halt, {:error, "subscription filter #{key} must be a boolean"}}

  defp normalize_filter_entry({key, _value}, {:ok, _acc}) when key in @list_filter_keys,
    do: {:halt, {:error, "subscription filter #{key} must be a list of strings"}}

  defp maybe_accept_flag(accepted, capabilities, path, key) do
    if Protocol.capability_flag?(capabilities, path),
      do: Map.put(accepted, key, true),
      else: accepted
  end

  defp subset?(requested, accepted) do
    Enum.all?(accepted, fn
      {key, true} ->
        Map.get(requested, key) == true

      {key, values} when is_list(values) ->
        Map.has_key?(requested, key) and
          MapSet.subset?(MapSet.new(values), MapSet.new(Map.fetch!(requested, key)))
    end)
  end
end
