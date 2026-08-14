defmodule FastestMCP.Lifespan do
  @moduledoc """
  Small server lifespan helper for startup and shutdown state.

  A lifespan can be registered as:

  - a one-arity function receiving the server and returning a map, `{:ok, map}`,
    `{map, cleanup}`, or `{:ok, map, cleanup}`
  - an explicit `{enter_fun, exit_fun}` pair

  Startup results are merged in declaration order, with later lifespans winning
  on key conflicts. Cleanup runs in reverse order.
  """

  defstruct [:enter, :exit, :namespace]

  require Logger

  @type cleanup :: (-> any()) | (map() -> any())
  @type enter ::
          (FastestMCP.Server.t() ->
             map()
             | {:ok, map()}
             | {map(), cleanup()}
             | {:ok, map(), cleanup()})
  @type exit :: nil | (-> any()) | (map() -> any()) | (FastestMCP.Server.t(), map() -> any())
  @type t :: %__MODULE__{enter: enter(), exit: exit(), namespace: String.t() | nil}

  @doc "Builds a new value for this module from the supplied options."
  def new(%__MODULE__{} = lifespan), do: lifespan
  def new({enter, exit}), do: new(enter, exit)

  def new(enter) when is_function(enter, 1) do
    %__MODULE__{enter: enter, exit: nil}
  end

  def new(enter, exit)
      when is_function(enter, 1) and
             (is_nil(exit) or is_function(exit, 0) or is_function(exit, 1) or is_function(exit, 2)) do
    %__MODULE__{enter: enter, exit: exit}
  end

  @doc false
  def namespaced(namespace, lifespan) when is_binary(namespace) and namespace != "" do
    %{new(lifespan) | namespace: namespace}
  end

  @doc "Runs all configured lifespan enter hooks and collects cleanup callbacks."
  def run_all(server, lifespans) when is_list(lifespans) do
    Enum.reduce_while(lifespans, {:ok, %{}, []}, fn lifespan, {:ok, merged, cleanups} ->
      case enter(server, lifespan) do
        {:ok, state, cleanup} ->
          merged = Map.merge(merged, state)
          cleanups = if is_nil(cleanup), do: cleanups, else: [cleanup | cleanups]
          {:cont, {:ok, merged, cleanups}}

        {:error, reason} ->
          cleanup_all(cleanups)
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Runs the collected cleanup callbacks."
  def cleanup_all(cleanups) when is_list(cleanups) do
    Enum.each(cleanups, &run_cleanup/1)

    :ok
  end

  defp run_cleanup(cleanup) do
    _ = cleanup.()
    :ok
  rescue
    error ->
      Logger.error("lifespan cleanup failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("lifespan cleanup failed: #{kind}: #{inspect(reason)}")
      :ok
  end

  defp enter(server, lifespan) do
    lifespan = new(lifespan)

    case lifespan.enter.(server) do
      %{} = state ->
        successful_enter(lifespan, state, wrap_exit(server, lifespan.exit, state))

      {:ok, %{} = state} ->
        successful_enter(lifespan, state, wrap_exit(server, lifespan.exit, state))

      {%{} = state, cleanup} ->
        successful_enter(lifespan, state, wrap_cleanup(cleanup, state))

      {:ok, %{} = state, cleanup} ->
        successful_enter(lifespan, state, wrap_cleanup(cleanup, state))

      nil ->
        successful_enter(lifespan, %{}, wrap_exit(server, lifespan.exit, %{}))

      {:ok, nil} ->
        successful_enter(lifespan, %{}, wrap_exit(server, lifespan.exit, %{}))

      other ->
        {:error, {:invalid_lifespan_result, other}}
    end
  rescue
    error ->
      {:error, error}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp successful_enter(%__MODULE__{namespace: nil}, state, cleanup),
    do: {:ok, state, cleanup}

  defp successful_enter(%__MODULE__{namespace: namespace}, state, cleanup),
    do: {:ok, %{namespace => state}, cleanup}

  defp wrap_exit(_server, nil, _state), do: nil
  defp wrap_exit(_server, exit, _state) when is_function(exit, 0), do: exit
  defp wrap_exit(_server, exit, state) when is_function(exit, 1), do: fn -> exit.(state) end

  defp wrap_exit(server, exit, state) when is_function(exit, 2),
    do: fn -> exit.(server, state) end

  defp wrap_cleanup(cleanup, _state) when is_function(cleanup, 0), do: cleanup
  defp wrap_cleanup(cleanup, state) when is_function(cleanup, 1), do: fn -> cleanup.(state) end
end
