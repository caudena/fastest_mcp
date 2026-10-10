defmodule FastestMCP.Client.Connection.Catalog do
  @moduledoc false
  # The connection's tool catalog, loaded by one caller while the others wait,
  # and its response cache. Both are dropped together when what they describe
  # changes. A caller selects the whole catalog (`:all`) or one tool's
  # `{name, version}`, which is answered with the descriptor lookup and the
  # connection snapshot.

  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.ResponseCache
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Error

  @enforce_keys [:tools, :responses]
  defstruct [:tools, :responses, ready?: false, load: nil]

  # A fresh catalog is answered at once, and so is a call of a tool that a
  # stale one lists: calls list the tools again only for a tool the catalog
  # lacks. Otherwise the first caller loads the catalog and later callers wait
  # for its `install/5`.
  def ensure(%State{catalog: catalog} = state, {loader, _tag} = from, select) do
    cond do
      catalog.ready? and usable?(catalog.tools, select) ->
        {:reply, {:ok, selection(state, catalog.tools, select)}, state}

      catalog.load ->
        {:noreply, update_in(state.catalog.load.waiters, &[{from, select} | &1])}

      true ->
        {ref, state} = State.monitor(state, loader, :catalog_loader)

        load = %{
          loader: loader,
          monitor_ref: ref,
          generation: catalog.tools.generation,
          waiters: []
        }

        {:reply, load_reply(state),
         %{state | catalog: %{state.catalog | ready?: false, load: load}}}
    end
  end

  defp usable?(tools, :all), do: ToolCatalog.fresh?(tools)

  defp usable?(tools, {name, version}),
    do: ToolCatalog.fresh?(tools) or ToolCatalog.lookup(tools, name, version) != :error

  def load_reply(state),
    do:
      {:load, state.catalog.tools.generation, state.config.schema_options,
       Lifecycle.snapshot(state)}

  def install(
        %State{catalog: %{load: %{loader: loader, generation: generation} = load}} = state,
        {loader, _tag},
        generation,
        result,
        select
      ) do
    state = State.demonitor(state, load.monitor_ref)

    case result do
      {:ok, %ToolCatalog{} = tools} ->
        state = %{state | catalog: %{state.catalog | tools: tools, ready?: true, load: nil}}

        Enum.each(load.waiters, fn {from, select} ->
          GenServer.reply(from, {:ok, selection(state, tools, select)})
        end)

        {{:ok, selection(state, tools, select)}, state}

      {:error, error} ->
        Enum.each(load.waiters, fn {from, _select} -> GenServer.reply(from, {:error, error}) end)
        {{:error, error}, %{state | catalog: %{state.catalog | load: nil}}}
    end
  end

  def install(state, _from, _generation, _result, _select), do: {:stale, state}

  defp selection(_state, tools, :all), do: tools

  defp selection(state, tools, {name, version}),
    do: {ToolCatalog.lookup(tools, name, version), Lifecycle.snapshot(state)}

  def loader_down(state, reason) do
    fail_load(state, %Error{
      code: :internal_error,
      message: "tool catalog loader exited",
      details: %{reason: inspect(reason)}
    })
  end

  def invalidate(%State{} = state, reason) do
    state =
      fail_load(state, %Error{
        code: :bad_request,
        message: "tool catalog was invalidated while loading",
        details: %{reason: reason}
      })

    catalog = state.catalog

    %{
      state
      | catalog: %{
          catalog
          | tools: %ToolCatalog{generation: catalog.tools.generation + 1},
            ready?: false,
            responses: ResponseCache.clear(catalog.responses)
        }
    }
  end

  def clear_responses(state), do: update_in(state.catalog.responses, &ResponseCache.clear/1)

  defp fail_load(%State{catalog: %{load: nil}} = state, _error), do: state

  defp fail_load(%State{catalog: %{load: load}} = state, error) do
    Enum.each(load.waiters, fn {from, _select} -> GenServer.reply(from, {:error, error}) end)

    state
    |> State.demonitor(load.monitor_ref)
    |> put_in([Access.key(:catalog), Access.key(:load)], nil)
  end
end
