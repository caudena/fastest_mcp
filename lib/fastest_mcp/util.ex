defmodule FastestMCP.Util do
  @moduledoc false

  @version Mix.Project.config()[:version]

  # FastestMCP's own version, as in its mix.exs.
  def version, do: @version

  def maybe_put(container, _key, nil), do: container
  def maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  def maybe_put(keyword, key, value) when is_list(keyword), do: Keyword.put(keyword, key, value)

  # Recursive through maps, structs, and lists.
  def stringify_keys(%_{} = struct), do: struct |> Map.from_struct() |> stringify_keys()

  def stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(other), do: other

  # Top-level keys only: the one normalization of a map that application code
  # may give with atom or string keys.
  def string_keys(map) do
    map
    |> Map.to_list()
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      entry -> entry
    end)
  end

  # Constant time; false for anything but two binaries.
  def secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: Plug.Crypto.secure_compare(left, right)

  def secure_equal?(_left, _right), do: false

  # Never creates an atom.
  def existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  # A process that is already gone counts as stopped.
  def stop_process(pid, reason \\ :normal) do
    GenServer.stop(pid, reason)
  catch
    :exit, _reason -> :ok
  end

  def optional_map!(nil, _label), do: nil
  def optional_map!(map, _label) when is_map(map), do: Map.new(map)

  def optional_map!(other, label),
    do: raise(ArgumentError, "#{label} must be a map, got #{inspect(other)}")

  # `build` must be deterministic: concurrent first calls may each build, and
  # storing an equal value is a no-op, so the entry is never replaced.
  def cached(key, build) do
    with nil <- :persistent_term.get(key, nil) do
      value = build.()
      :persistent_term.put(key, value)
      value
    end
  end
end
