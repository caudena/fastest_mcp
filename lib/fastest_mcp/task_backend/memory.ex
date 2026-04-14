defmodule FastestMCP.TaskBackend.Memory do
  @moduledoc """
  ETS-backed in-memory task backend.

  The default implementation keeps one private ETS table for task bodies and
  dedicated ordered indexes for listing and expiry:

      tasks              -> task_id => task
      created_index      -> {-submitted_at, task_id} => session_id
      session_created    -> {session_id, -submitted_at, task_id} => true
      expiry_index       -> {expires_at, task_id} => true

  The important part is not the exact table layout; it is that the runtime can
  paginate and prune without re-sorting the full task set on every request.
  """

  use GenServer

  @behaviour FastestMCP.TaskBackend

  alias FastestMCP.Error

  @doc "Starts the process owned by this module."
  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stores or replaces one task."
  @impl true
  def put_task(store, task) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:put_task, task})
  end

  @doc "Fetches one stored task."
  @impl true
  def fetch_task(store, task_id, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:fetch_task, to_string(task_id), opts})
  end

  @doc "Deletes one stored task."
  @impl true
  def delete_task(store, task_id) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:delete_task, to_string(task_id)})
  end

  @doc "Lists tasks with cursor pagination."
  @impl true
  def list_tasks(store, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:list_tasks, opts})
  end

  @doc "Deletes expired tasks and returns their task ids."
  @impl true
  def expire_tasks(store, now_ms) when (is_pid(store) or is_atom(store)) and is_integer(now_ms) do
    GenServer.call(store, {:expire_tasks, now_ms})
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       # These tables are private, so the name atom is only a placeholder.
       # Reusing fixed atoms avoids leaking one atom per backend instance.
       tasks:
         :ets.new(:fastest_mcp_task_backend_tasks, [
           :set,
           :private,
           read_concurrency: true
         ]),
       created_index:
         :ets.new(:fastest_mcp_task_backend_created, [
           :ordered_set,
           :private
         ]),
       session_created_index:
         :ets.new(:fastest_mcp_task_backend_session_created, [
           :ordered_set,
           :private
         ]),
       expiry_index:
         :ets.new(:fastest_mcp_task_backend_expiry, [
           :ordered_set,
           :private
         ])
     }}
  end

  @impl true
  def handle_call({:put_task, task}, _from, state) do
    state = maybe_remove_existing_task(state, task.id)
    insert_task(state, task)
    {:reply, :ok, state}
  end

  def handle_call({:fetch_task, task_id, opts}, _from, state) do
    {:reply, fetch_task_reply(state, task_id, opts), state}
  end

  def handle_call({:delete_task, task_id}, _from, state) do
    remove_task(state, task_id)
    {:reply, :ok, state}
  end

  def handle_call({:list_tasks, opts}, _from, state) do
    reply =
      try do
        list_tasks_reply(state, opts)
      rescue
        error in FastestMCP.Error -> {:error, error}
      end

    {:reply, reply, state}
  end

  def handle_call({:expire_tasks, now_ms}, _from, state) do
    {:reply, expire_tasks_reply(state, now_ms), state}
  end

  defp fetch_task_reply(state, task_id, opts) do
    owner_fingerprint = owner_filter(opts)

    case :ets.lookup(state.tasks, task_id) do
      [{^task_id, task}] ->
        if session_matches?(task, opts[:session_id]) and owner_matches?(task, owner_fingerprint),
          do: {:ok, task},
          else: :error

      [] ->
        :error
    end
  end

  defp list_tasks_reply(state, opts) do
    session_id = normalize_session_id(opts[:session_id])
    owner_fingerprint = owner_filter(opts)
    page_size = opts[:page_size]
    cursor = decode_cursor(opts[:cursor], session_id, owner_fingerprint)

    tasks =
      case page_size do
        nil ->
          list_all_tasks(state, session_id, owner_fingerprint, cursor)

        value when is_integer(value) and value > 0 ->
          list_page(state, session_id, owner_fingerprint, cursor, value)

        _other ->
          raise Error, code: :bad_request, message: "page_size must be a positive integer"
      end

    {:ok, tasks}
  end

  defp expire_tasks_reply(state, now_ms) do
    expire_tasks(state, now_ms, [])
  end

  defp expire_tasks(state, now_ms, expired_ids) do
    case :ets.first(state.expiry_index) do
      {expires_at, task_id} when is_integer(expires_at) and expires_at <= now_ms ->
        remove_task(state, task_id)
        expire_tasks(state, now_ms, [task_id | expired_ids])

      _other ->
        Enum.reverse(expired_ids)
    end
  end

  defp list_all_tasks(state, session_id, owner_fingerprint, cursor) do
    iterate_index(state, session_id, owner_fingerprint, cursor, :infinity, [])
  end

  defp list_page(state, session_id, owner_fingerprint, cursor, page_size) do
    {tasks, _next_key} =
      iterate_index(state, session_id, owner_fingerprint, cursor, page_size + 1, [])

    {page, overflow} = Enum.split(tasks, page_size)

    %{
      tasks: page,
      next_cursor:
        if overflow == [] do
          nil
        else
          encode_cursor(session_id, owner_fingerprint, next_key_for_page(page, session_id))
        end
    }
  end

  defp iterate_index(state, session_id, owner_fingerprint, cursor, limit, acc) do
    do_iterate_index(
      state,
      session_id,
      owner_fingerprint,
      next_index_key(state, session_id, cursor),
      limit,
      acc
    )
  end

  defp do_iterate_index(_state, _session_id, _owner_fingerprint, :"$end_of_table", :infinity, acc) do
    %{tasks: Enum.reverse(acc), next_cursor: nil}
  end

  defp do_iterate_index(state, session_id, owner_fingerprint, key, :infinity, acc) do
    case fetch_task_for_index(state, session_id, owner_fingerprint, key) do
      nil ->
        do_iterate_index(
          state,
          session_id,
          owner_fingerprint,
          next_index_key(state, session_id, key),
          :infinity,
          acc
        )

      task ->
        do_iterate_index(
          state,
          session_id,
          owner_fingerprint,
          next_index_key(state, session_id, key),
          :infinity,
          [task | acc]
        )
    end
  end

  defp do_iterate_index(_state, _session_id, _owner_fingerprint, _key, 0, acc) do
    {Enum.reverse(acc), nil}
  end

  defp do_iterate_index(_state, _session_id, _owner_fingerprint, :"$end_of_table", _limit, acc) do
    {Enum.reverse(acc), nil}
  end

  defp do_iterate_index(state, session_id, owner_fingerprint, key, limit, acc) do
    case fetch_task_for_index(state, session_id, owner_fingerprint, key) do
      nil ->
        do_iterate_index(
          state,
          session_id,
          owner_fingerprint,
          next_index_key(state, session_id, key),
          limit,
          acc
        )

      task ->
        do_iterate_index(
          state,
          session_id,
          owner_fingerprint,
          next_index_key(state, session_id, key),
          limit - 1,
          [task | acc]
        )
    end
  end

  defp fetch_task_for_index(state, nil, owner_fingerprint, {_, task_id}) do
    case :ets.lookup(state.tasks, task_id) do
      [{^task_id, task}] ->
        if owner_matches?(task, owner_fingerprint), do: task, else: nil

      [] ->
        nil
    end
  end

  defp fetch_task_for_index(state, session_id, owner_fingerprint, {session_id, _, task_id}) do
    case :ets.lookup(state.tasks, task_id) do
      [{^task_id, task}] ->
        if owner_matches?(task, owner_fingerprint), do: task, else: nil

      [] ->
        nil
    end
  end

  defp fetch_task_for_index(_state, _session_id, _owner_fingerprint, _key), do: nil

  defp next_index_key(state, nil, nil), do: :ets.first(state.created_index)
  defp next_index_key(state, nil, key), do: :ets.next(state.created_index, key)

  defp next_index_key(state, session_id, nil) do
    start_key = {session_id, min_index_value(), ""}
    :ets.next(state.session_created_index, start_key)
  end

  defp next_index_key(state, _session_id, key), do: :ets.next(state.session_created_index, key)

  defp maybe_remove_existing_task(state, task_id) do
    case :ets.lookup(state.tasks, task_id) do
      [{^task_id, _existing}] -> remove_task(state, task_id)
      [] -> state
    end
  end

  defp insert_task(state, task) do
    true = :ets.insert(state.tasks, {task.id, task})
    true = :ets.insert(state.created_index, {created_index_key(task), task.session_id})

    if is_binary(task.session_id) and task.session_id != "" do
      true = :ets.insert(state.session_created_index, {session_created_index_key(task), true})
    end

    if is_integer(task.expires_at) do
      true = :ets.insert(state.expiry_index, {expiry_index_key(task), true})
    end

    state
  end

  defp remove_task(state, task_id) do
    case :ets.lookup(state.tasks, task_id) do
      [{^task_id, task}] ->
        true = :ets.delete(state.tasks, task_id)
        true = :ets.delete(state.created_index, created_index_key(task))

        if is_binary(task.session_id) and task.session_id != "" do
          true = :ets.delete(state.session_created_index, session_created_index_key(task))
        end

        if is_integer(task.expires_at) do
          true = :ets.delete(state.expiry_index, expiry_index_key(task))
        end

        state

      [] ->
        state
    end
  end

  defp created_index_key(task), do: {-task.submitted_at, task.id}
  defp session_created_index_key(task), do: {task.session_id, -task.submitted_at, task.id}
  defp expiry_index_key(task), do: {task.expires_at, task.id}

  defp next_key_for_page([], _session_id), do: nil

  defp next_key_for_page(tasks, session_id) do
    last = List.last(tasks)

    if is_binary(session_id) and session_id != "" do
      session_created_index_key(last)
    else
      created_index_key(last)
    end
  end

  defp session_matches?(_task, nil), do: true
  defp session_matches?(task, session_id), do: task.session_id == normalize_session_id(session_id)
  defp owner_matches?(_task, :any), do: true

  defp owner_matches?(task, owner_fingerprint),
    do: Map.get(task, :owner_fingerprint) == normalize_owner_fingerprint(owner_fingerprint)

  defp normalize_session_id(nil), do: nil
  defp normalize_session_id(session_id), do: to_string(session_id)
  defp normalize_owner_fingerprint(nil), do: nil
  defp normalize_owner_fingerprint(owner_fingerprint), do: to_string(owner_fingerprint)

  defp owner_filter(opts) do
    if Keyword.has_key?(opts, :owner_fingerprint) do
      normalize_owner_fingerprint(opts[:owner_fingerprint])
    else
      :any
    end
  end

  defp min_index_value, do: -9_223_372_036_854_775_808

  defp encode_cursor(session_id, owner_fingerprint, key) do
    owner_fingerprint = cursor_owner_fingerprint(owner_fingerprint)

    %{}
    |> Map.put("scope", if(is_nil(session_id), do: "all", else: "session"))
    |> maybe_put("sessionId", session_id)
    |> maybe_put("ownerFingerprint", owner_fingerprint)
    |> Map.put("after", Tuple.to_list(key))
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _session_id, _owner_fingerprint), do: nil

  defp decode_cursor(cursor, session_id, owner_fingerprint)
       when is_binary(cursor) and cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"scope" => scope, "after" => after_parts} = payload} <- Jason.decode(decoded),
         {:ok, key} <-
           decode_cursor_key(scope, after_parts, payload, session_id, owner_fingerprint) do
      key
    else
      _other ->
        raise Error, code: :bad_request, message: "invalid cursor"
    end
  end

  defp decode_cursor(_cursor, _session_id, _owner_fingerprint) do
    raise Error, code: :bad_request, message: "invalid cursor"
  end

  defp decode_cursor_key("all", [submitted_at, task_id], payload, nil, expected_owner_fingerprint)
       when is_integer(submitted_at) and is_binary(task_id) do
    if Map.get(payload, "ownerFingerprint") ==
         cursor_owner_fingerprint(expected_owner_fingerprint) do
      {:ok, {submitted_at, task_id}}
    else
      {:error, :invalid_cursor}
    end
  end

  defp decode_cursor_key(
         "session",
         [session_id, submitted_at, task_id],
         payload,
         expected_session_id,
         expected_owner_fingerprint
       )
       when is_binary(session_id) and is_integer(submitted_at) and is_binary(task_id) do
    payload_session_id = Map.get(payload, "sessionId", session_id)

    if payload_session_id == expected_session_id and
         Map.get(payload, "ownerFingerprint") ==
           cursor_owner_fingerprint(expected_owner_fingerprint) do
      {:ok, {session_id, submitted_at, task_id}}
    else
      {:error, :invalid_cursor}
    end
  end

  defp decode_cursor_key(_scope, _after_parts, _payload, _session_id, _owner_fingerprint),
    do: {:error, :invalid_cursor}

  defp cursor_owner_fingerprint(:any), do: nil
  defp cursor_owner_fingerprint(owner_fingerprint), do: owner_fingerprint

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
