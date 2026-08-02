defmodule FastestMCP.Providers.Skills.Common do
  @moduledoc """
  Shared helpers for parsing skill directories and their supporting files.

  This module is a thin adapter over `FastestMCP.Providers.SkillsDirectory`.
  Its job is to point the shared directory scanner at the conventional paths
  and file layout used by this editor or agent environment.

  Use these helpers when you want to expose locally installed skills as MCP
  resources without hard-coding directory conventions in your application.
  """

  alias FastestMCP.PathSafety

  defmodule SkillFileInfo do
    @moduledoc """
    Metadata describing one file inside a loaded skill directory.
    """

    defstruct [:path, :size, :hash]
  end

  defmodule SkillInfo do
    @moduledoc """
    Normalized description of a loaded skill directory.
    """

    defstruct [:name, :description, :path, :real_path, :main_file, files: [], frontmatter: %{}]
  end

  @frontmatter_end ~r/\n---\s*\n/

  @doc "Parses optional frontmatter from the given content."
  def parse_frontmatter(content) when is_binary(content) do
    if String.starts_with?(content, "---") do
      parse_frontmatter_block(content)
    else
      {%{}, content}
    end
  end

  @doc "Loads one skill directory into a normalized description."
  def load_skill!(skill_path, main_file_name \\ "SKILL.md") do
    skill_path = Path.expand(to_string(skill_path))
    main_file_path = Path.join(skill_path, main_file_name)

    unless File.dir?(skill_path) do
      raise File.Error, reason: :enoent, action: "read directory", path: skill_path
    end

    real_path = PathSafety.realpath!(skill_path)

    real_main_file_path =
      case PathSafety.safe_realpath(real_path, main_file_path) do
        {:ok, path} ->
          path

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read file", path: main_file_path
      end

    unless File.regular?(real_main_file_path) do
      raise File.Error, reason: :enoent, action: "read file", path: main_file_path
    end

    content = File.read!(real_main_file_path)
    {frontmatter, body} = parse_frontmatter(content)

    %SkillInfo{
      name: Path.basename(skill_path),
      description: description_from(frontmatter, body, Path.basename(skill_path)),
      path: skill_path,
      real_path: real_path,
      main_file: main_file_name,
      files: scan_skill_files(skill_path, real_path),
      frontmatter: frontmatter
    }
  end

  @doc false
  def skill_metadata_key(skill_path, main_file_name \\ "SKILL.md") do
    skill_path = Path.expand(to_string(skill_path))

    with {:ok, real_root} <- PathSafety.realpath(skill_path),
         {:ok, files} <- safe_skill_files(skill_path, real_root),
         true <-
           Enum.any?(files, fn {relative_path, _real_path} ->
             relative_path == main_file_name
           end) do
      metadata =
        Enum.map(files, fn {relative_path, real_path} ->
          stat = File.stat!(real_path)

          {relative_path, real_path, stat.size, stat.mtime, stat.ctime, stat.inode, stat.mode}
        end)

      {:ok, {real_root, metadata}}
    else
      false -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Builds the JSON manifest payload for a loaded skill."
  def manifest_json(%SkillInfo{} = skill_info) do
    JSON.encode!(%{
      "skill" => skill_info.name,
      "files" =>
        Enum.map(skill_info.files, fn file ->
          %{"path" => file.path, "size" => file.size, "hash" => file.hash}
        end)
    })
  end

  @doc "Infers the mime type for the given file path."
  def infer_mime_type(path) do
    case String.downcase(Path.extname(path)) do
      ".md" -> "text/markdown"
      "" -> "application/octet-stream"
      _ -> MIME.from_path(path)
    end
  end

  @doc "Resolves a supporting file path while keeping it inside the skill root."
  def safe_file_path(%SkillInfo{} = skill_info, relative_path) do
    relative_path = to_string(relative_path)

    if Path.type(relative_path) == :relative do
      joined_path = Path.expand(relative_path, skill_info.path)

      with {:ok, real_path} <- PathSafety.safe_realpath(skill_info.real_path, joined_path),
           true <- File.regular?(real_path) do
        {:ok, real_path}
      else
        {:error, reason} -> {:error, reason}
        false -> {:error, :enoent}
      end
    else
      {:error, :invalid_path}
    end
  end

  @doc "Returns the path relative to the skill root."
  def relative_file_path(%SkillInfo{} = skill_info, real_path) do
    real_path
    |> Path.relative_to(skill_info.real_path)
    |> String.replace("\\", "/")
  end

  defp parse_frontmatter_block(content) do
    case Regex.run(@frontmatter_end, binary_part(content, 3, byte_size(content) - 3),
           return: :index
         ) do
      [{start, length}] ->
        frontmatter_text = binary_part(content, 3, start)
        body_offset = 3 + start + length
        body = binary_part(content, body_offset, byte_size(content) - body_offset)
        {parse_frontmatter_lines(frontmatter_text), body}

      nil ->
        {%{}, content}
    end
  end

  defp parse_frontmatter_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          Map.put(acc, String.trim(key), parse_frontmatter_value(String.trim(value)))

        _ ->
          acc
      end
    end)
  end

  defp parse_frontmatter_value("[" <> rest) do
    if String.ends_with?(rest, "]") do
      rest
      |> String.trim_trailing("]")
      |> String.split(",", trim: true)
      |> Enum.map(&strip_quotes/1)
    else
      "[" <> rest
    end
  end

  defp parse_frontmatter_value(value), do: strip_quotes(value)

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> case do
      "\"" <> rest -> rest |> String.trim_trailing("\"")
      "'" <> rest -> rest |> String.trim_trailing("'")
      other -> other
    end
  end

  defp description_from(frontmatter, body, fallback_name) do
    case Map.get(frontmatter, "description") do
      description when is_binary(description) and description != "" ->
        description

      _ ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value(fallback_name, fn
          "" -> nil
          "#" <> heading -> String.trim(heading)
          line -> line
        end)
    end
  end

  defp scan_skill_files(skill_path, real_root) do
    {:ok, files} = safe_skill_files(skill_path, real_root)

    Enum.map(files, fn {relative_path, real_path} ->
      %SkillFileInfo{
        path: relative_path,
        size: File.stat!(real_path).size,
        hash: "sha256:" <> sha256_file(real_path)
      }
    end)
  end

  defp sha256_file(path) do
    path
    |> File.stream!(8192, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp safe_skill_files(skill_path, real_root) do
    case walk_skill_files(skill_path, skill_path, real_root, MapSet.new()) do
      {:ok, files, _visited} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_skill_files(logical_path, skill_path, real_root, visited) do
    with {:ok, real_path} <- PathSafety.realpath(logical_path),
         true <- PathSafety.within?(real_root, real_path),
         false <- MapSet.member?(visited, real_path),
         {:ok, entries} <- File.ls(logical_path) do
      visited = MapSet.put(visited, real_path)

      {files, visited} =
        entries
        |> Enum.sort()
        |> Enum.reduce({[], visited}, fn entry, {files, visited} ->
          child = Path.join(logical_path, entry)

          case safe_child(child, real_root) do
            {:ok, _real_child, :directory} ->
              case walk_skill_files(child, skill_path, real_root, visited) do
                {:ok, nested, visited} -> {Enum.reverse(nested, files), visited}
                {:error, _reason} -> {files, visited}
              end

            {:ok, real_child, :regular} ->
              relative_path =
                child
                |> Path.relative_to(skill_path)
                |> String.replace("\\", "/")

              {[{relative_path, real_child} | files], visited}

            _other ->
              {files, visited}
          end
        end)

      {:ok, Enum.reverse(files), visited}
    else
      false -> {:ok, [], visited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_child(path, real_root) do
    with {:ok, real_path} <- PathSafety.realpath(path),
         true <- PathSafety.within?(real_root, real_path),
         {:ok, %File.Stat{type: type}} <- File.stat(real_path) do
      {:ok, real_path, type}
    else
      _other -> :error
    end
  end
end
