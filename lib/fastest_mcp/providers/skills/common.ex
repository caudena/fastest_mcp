defmodule FastestMCP.Providers.Skills.Common do
  @moduledoc """
  Shared helpers for parsing skill directories and their supporting files.

  This module is a thin adapter over `FastestMCP.Providers.SkillsDirectory`.
  Its job is to point the shared directory scanner at the conventional paths
  and file layout used by this editor or agent environment.

  Use these helpers when you want to expose locally installed skills as MCP
  resources without hard-coding directory conventions in your application.
  """

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

    unless File.regular?(main_file_path) do
      raise File.Error, reason: :enoent, action: "read file", path: main_file_path
    end

    content = File.read!(main_file_path)
    {frontmatter, body} = parse_frontmatter(content)
    real_path = realpath!(skill_path)

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

  @doc "Builds the JSON manifest payload for a loaded skill."
  def manifest_json(%SkillInfo{} = skill_info) do
    Jason.encode!(%{
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
    joined_path = Path.join(skill_info.path, to_string(relative_path))

    with {:ok, real_path} <- realpath(joined_path),
         :ok <- assert_within_root(skill_info.real_path, real_path),
         true <- File.regular?(real_path) do
      {:ok, real_path}
    else
      {:error, reason} ->
        {:error, reason}

      false ->
        {:error, :enoent}

      :error ->
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
    skill_path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce([], fn path, files ->
      cond do
        not File.regular?(path) ->
          files

        true ->
          case realpath(path) do
            {:ok, real_path} ->
              case assert_within_root(real_root, real_path) do
                :ok ->
                  relative_path = Path.relative_to(path, skill_path) |> String.replace("\\", "/")

                  [
                    %SkillFileInfo{
                      path: relative_path,
                      size: File.stat!(real_path).size,
                      hash: "sha256:" <> sha256_file(real_path)
                    }
                    | files
                  ]

                :error ->
                  files
              end

            {:error, _reason} ->
              files
          end
      end
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 8192)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp realpath!(path) do
    case realpath(path) do
      {:ok, resolved_path} ->
        resolved_path

      {:error, reason} ->
        raise File.Error, reason: reason, action: "resolve path", path: path
    end
  end

  defp realpath(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_segments([], MapSet.new())
  end

  defp resolve_segments([], resolved_segments, _seen) do
    {:ok, resolved_segments |> Enum.reverse() |> Path.join() |> normalize_rooted_path()}
  end

  defp resolve_segments([segment | rest], resolved_segments, seen) do
    candidate =
      [segment | resolved_segments] |> Enum.reverse() |> Path.join() |> normalize_rooted_path()

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        if MapSet.member?(seen, candidate) do
          {:error, :eloop}
        else
          with {:ok, link_target} <- File.read_link(candidate) do
            target_path =
              if Path.type(link_target) == :absolute do
                link_target
              else
                Path.expand(link_target, Path.dirname(candidate))
              end

            case realpath(target_path) do
              {:ok, resolved_target} ->
                target_segments = Path.split(resolved_target)
                resolve_segments(rest, Enum.reverse(target_segments), MapSet.put(seen, candidate))

              {:error, reason} ->
                {:error, reason}
            end
          end
        end

      {:ok, _stat} ->
        resolve_segments(rest, [segment | resolved_segments], seen)

      {:error, _reason} when rest == [] ->
        # Preserve the final path for not-yet-existing files while still allowing
        # path escape checks on the expanded location.
        {:ok,
         [segment | resolved_segments] |> Enum.reverse() |> Path.join() |> normalize_rooted_path()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_rooted_path("/"), do: "/"

  defp normalize_rooted_path(path) do
    if String.starts_with?(path, "/") do
      path
    else
      "/" <> path
    end
  end

  defp assert_within_root(root, path) do
    root = String.trim_trailing(root, "/")
    path = String.trim_trailing(path, "/")

    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      :error
    end
  end
end
