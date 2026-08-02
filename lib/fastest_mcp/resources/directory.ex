defmodule FastestMCP.Resources.Directory do
  @moduledoc """
  Helper for serving directory listings as JSON resources.

  This helper covers the common directory-resource cases:

    * absolute-path validation
    * non-recursive or recursive file listing
    * optional hidden-file inclusion
    * normalized read errors

  `read/1` returns a `FastestMCP.Resources.Result` with one JSON content item.
  That keeps the result transport-safe while still making the directory listing
  explicit and inspectable in Elixir code.

  ## Example

  ```elixir
  directory = FastestMCP.Resources.Directory.new("/tmp/reports", recursive: true)

  FastestMCP.add_resource(server, "dir:///tmp/reports", fn _arguments, _ctx ->
    FastestMCP.Resources.Directory.read(directory)
  end)
  ```
  """

  alias FastestMCP.Error
  alias FastestMCP.PathSafety
  alias FastestMCP.Resources.Content
  alias FastestMCP.Resources.Result

  defstruct [:path, :mime_type, recursive: false, include_hidden: false]

  @type t :: %__MODULE__{
          path: Path.t(),
          mime_type: String.t(),
          recursive: boolean(),
          include_hidden: boolean()
        }

  @doc "Builds a directory-listing resource helper."
  def new(path, opts \\ []) do
    original_path = to_string(path)

    if Path.type(original_path) != :absolute do
      raise ArgumentError, "path must be absolute"
    end

    %__MODULE__{
      path: Path.expand(original_path),
      mime_type: Keyword.get(opts, :mime_type, "application/json"),
      recursive: Keyword.get(opts, :recursive, false),
      include_hidden: Keyword.get(opts, :include_hidden, false)
    }
  end

  @doc "Lists files in the configured directory."
  def list_files(%__MODULE__{} = directory) do
    try do
      validate_directory!(directory.path)
      real_root = PathSafety.realpath!(directory.path)

      directory.path
      |> walk(real_root, directory.recursive, directory.include_hidden, MapSet.new())
      |> elem(0)
    rescue
      error ->
        raise Error,
          code: :internal_error,
          message:
            "Error listing directory #{inspect(directory.path)}: #{Exception.message(error)}"
    end
  end

  @doc "Reads the directory listing and returns a normalized resource result."
  def read(%__MODULE__{} = directory) do
    try do
      files = list_files(directory)

      entries =
        Enum.map(files, fn path ->
          %{
            path: path,
            relative_path: Path.relative_to(path, directory.path),
            name: Path.basename(path),
            size_bytes: file_size(path)
          }
        end)

      Result.new(
        [
          Content.new(entries, mime_type: directory.mime_type)
        ],
        meta: %{
          count: length(entries),
          path: directory.path,
          recursive: directory.recursive
        }
      )
    rescue
      error in [Error] ->
        reraise error, __STACKTRACE__

      error ->
        raise Error,
          code: :internal_error,
          message:
            "Error reading directory #{inspect(directory.path)}: #{Exception.message(error)}"
    end
  end

  defp validate_directory!(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> raise ArgumentError, "path must point to a directory"
      {:error, reason} -> raise File.Error, reason: reason, action: "list", path: path
    end
  end

  defp walk(path, real_root, recursive?, include_hidden?, visited) do
    with {:ok, real_path} <- PathSafety.realpath(path),
         true <- PathSafety.within?(real_root, real_path),
         false <- MapSet.member?(visited, real_path) do
      visited = MapSet.put(visited, real_path)

      {files, visited} =
        path
        |> File.ls!()
        |> Enum.reject(&(hidden?(&1) and not include_hidden?))
        |> Enum.sort()
        |> Enum.reduce({[], visited}, fn entry, {files, visited} ->
          child = Path.join(path, entry)

          case safe_child(child, real_root) do
            {:ok, :directory} when recursive? ->
              {nested, visited} =
                walk(child, real_root, recursive?, include_hidden?, visited)

              {Enum.reverse(nested, files), visited}

            {:ok, :directory} ->
              {files, visited}

            {:ok, _type} ->
              {[child | files], visited}

            :error ->
              {files, visited}
          end
        end)

      {Enum.reverse(files), visited}
    else
      false -> {[], visited}
      {:error, _reason} -> {[], visited}
    end
  end

  defp safe_child(path, real_root) do
    with {:ok, real_path} <- PathSafety.realpath(path),
         true <- PathSafety.within?(real_root, real_path),
         {:ok, %File.Stat{type: type}} <- File.stat(real_path) do
      {:ok, type}
    else
      _other -> :error
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")
end
