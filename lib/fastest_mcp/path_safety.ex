defmodule FastestMCP.PathSafety do
  @moduledoc """
  Canonical-path helpers for filesystem-backed providers and resources.

  The resolver follows symlinks one segment at a time, detects cycles, and
  returns explicit filesystem errors. Containment checks operate on canonical
  absolute paths so sibling prefixes cannot be mistaken for descendants.
  """

  @max_symlinks 40

  @doc "Resolves an existing path to its canonical absolute path."
  def realpath(path) do
    path
    |> to_string()
    |> Path.expand()
    |> path_segments()
    |> resolve_segments("/", %{}, 0)
  end

  @doc "Resolves an existing path, raising `File.Error` on failure."
  def realpath!(path) do
    case realpath(path) do
      {:ok, resolved_path} ->
        resolved_path

      {:error, reason} ->
        raise File.Error, reason: reason, action: "resolve path", path: to_string(path)
    end
  end

  @doc "Returns whether a canonical path is the root itself or one of its descendants."
  def within?(root, path) when is_binary(root) and is_binary(path) do
    root = normalize_root(root)
    path = normalize_root(path)

    root == "/" or path == root or String.starts_with?(path, root <> "/")
  end

  @doc "Resolves a path and verifies that it remains inside a canonical root."
  def safe_realpath(root, path) do
    with {:ok, real_root} <- realpath(root),
         {:ok, real_path} <- realpath(path),
         true <- within?(real_root, real_path) do
      {:ok, real_path}
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_segments([], resolved, _seen, _count), do: {:ok, normalize_root(resolved)}

  defp resolve_segments([segment | rest], resolved, seen, count) do
    candidate = Path.join(resolved, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(candidate, rest, seen, count)

      {:ok, _stat} ->
        resolve_segments(rest, candidate, seen, count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(_candidate, _rest, _seen, count) when count >= @max_symlinks,
    do: {:error, :eloop}

  defp resolve_symlink(candidate, rest, seen, count) do
    resolution_state = {candidate, rest}

    if Map.has_key?(seen, resolution_state) do
      {:error, :eloop}
    else
      with {:ok, target} <- File.read_link(candidate) do
        target =
          if Path.type(target) == :absolute,
            do: Path.expand(target),
            else: Path.expand(target, Path.dirname(candidate))

        resolve_segments(
          path_segments(target) ++ rest,
          "/",
          Map.put(seen, resolution_state, true),
          count + 1
        )
      end
    end
  end

  defp path_segments(path) do
    case Path.split(path) do
      ["/" | segments] -> segments
      segments -> segments
    end
  end

  defp normalize_root("/"), do: "/"
  defp normalize_root(path), do: String.trim_trailing(path, "/")
end
