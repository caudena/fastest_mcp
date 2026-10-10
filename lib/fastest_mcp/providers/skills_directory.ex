defmodule FastestMCP.Providers.SkillsDirectory do
  @moduledoc """
  A provider that exposes skill directories as MCP resources: each skill's main
  file, a `_manifest`, and its supporting files.

      FastestMCP.server("skills")
      |> FastestMCP.add_provider(
        FastestMCP.Providers.SkillsDirectory.new(roots: ["~/.claude/skills"])
      )

  `FastestMCP.Providers.Skills.vendor/2` builds one for an agent's
  conventional skill folders. The [Providers and Mounting](providers-and-mounting.md)
  guide describes discovery and path safety.
  """

  use FastestMCP.Provider

  alias FastestMCP.PathSafety
  alias FastestMCP.Provider
  alias FastestMCP.Providers.Skill
  alias FastestMCP.Providers.Skills.Common

  defstruct roots: [],
            reload: false,
            main_file_name: "SKILL.md",
            supporting_files: :template,
            providers: [],
            cache: nil

  @doc """
  Discovers the skills under `:roots` (a path or a list; earlier roots win
  when skill names collide). Other options: `:main_file_name` (default
  `"SKILL.md"`), `:supporting_files` (`:template`, the default, serves them
  through one resource template; `:resources` lists each file), and `:reload`
  (default `false`; `true` re-reads changed files while the server runs
  instead of discovering once here).
  """
  def new(opts) when is_list(opts) do
    roots = normalize_roots(Keyword.get(opts, :roots, []))
    main_file_name = Keyword.get(opts, :main_file_name, "SKILL.md")
    supporting_files = Keyword.get(opts, :supporting_files, :template)
    reload = Keyword.get(opts, :reload, false)

    providers =
      if reload do
        []
      else
        discover_skills(roots, main_file_name, supporting_files, nil)
      end

    %__MODULE__{
      roots: roots,
      reload: reload,
      main_file_name: main_file_name,
      supporting_files: supporting_files,
      providers: providers
    }
  end

  @impl FastestMCP.Provider
  def provider_type(%__MODULE__{}), do: "SkillsDirectoryProvider"

  @impl FastestMCP.Provider
  def activate_runtime(%__MODULE__{reload: false} = provider), do: {:ok, provider}

  def activate_runtime(%__MODULE__{reload: true} = provider) do
    with {:ok, cache} <- __MODULE__.ReloadCache.start_link(),
         do: {:ok, %{provider | cache: cache}}
  end

  @impl FastestMCP.Provider
  def deactivate_runtime(%__MODULE__{cache: cache}) when is_pid(cache),
    do: FastestMCP.Util.stop_process(cache)

  def deactivate_runtime(%__MODULE__{}), do: :ok

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{} = provider, component_type, operation) do
    provider
    |> current_providers()
    |> Enum.flat_map(&Provider.Dispatch.list_components(&1, component_type, operation))
  end

  defp current_providers(%__MODULE__{reload: true, cache: cache} = provider) do
    discover_skills(
      provider.roots,
      provider.main_file_name,
      provider.supporting_files,
      active_cache(cache)
    )
  end

  defp current_providers(%__MODULE__{} = provider), do: provider.providers

  defp discover_skills(roots, main_file_name, supporting_files, cache) do
    roots
    |> Enum.reduce({MapSet.new(), []}, fn root, acc ->
      discover_root(root, main_file_name, supporting_files, cache, acc)
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp discover_root(root, main_file_name, supporting_files, cache, {seen_names, providers}) do
    with {:ok, real_root} <- PathSafety.realpath(root),
         {:ok, %File.Stat{type: :directory}} <- File.stat(real_root),
         {:ok, entries} <- File.ls(root) do
      entries
      |> Enum.sort()
      |> Enum.reduce({seen_names, providers}, fn entry, {seen, acc} ->
        skill_path = Path.join(root, entry)

        cond do
          MapSet.member?(seen, entry) ->
            {seen, acc}

          not safe_skill_directory?(skill_path, real_root) ->
            {seen, acc}

          true ->
            case load_provider(skill_path, main_file_name, supporting_files, cache) do
              {:ok, provider} -> {MapSet.put(seen, entry), [provider | acc]}
              {:error, _reason} -> {seen, acc}
            end
        end
      end)
    else
      _other -> {seen_names, providers}
    end
  end

  defp safe_skill_directory?(skill_path, real_root) do
    with {:ok, real_path} <- PathSafety.realpath(skill_path),
         true <- PathSafety.within?(real_root, real_path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(real_path) do
      true
    else
      _other -> false
    end
  end

  defp load_provider(skill_path, main_file_name, supporting_files, nil) do
    {:ok, build_provider(skill_path, main_file_name, supporting_files)}
  rescue
    _error in [File.Error] -> {:error, :invalid_skill}
  end

  defp load_provider(skill_path, main_file_name, supporting_files, cache) when is_pid(cache) do
    with {:ok, metadata_key} <- Common.skill_metadata_key(skill_path, main_file_name) do
      cache_key = {Path.expand(skill_path), main_file_name, supporting_files}

      case __MODULE__.ReloadCache.lookup(cache, cache_key, metadata_key) do
        {:ok, provider} ->
          {:ok, provider}

        :error ->
          provider = build_provider(skill_path, main_file_name, supporting_files)

          :ok = __MODULE__.ReloadCache.put(cache, cache_key, metadata_key, provider)
          {:ok, provider}
      end
    end
  rescue
    _error in [File.Error] -> {:error, :invalid_skill}
  end

  defp build_provider(skill_path, main_file_name, supporting_files) do
    skill_path
    |> Skill.new(main_file_name: main_file_name, supporting_files: supporting_files)
    |> Provider.new()
  end

  defp active_cache(cache) when is_pid(cache) do
    if Process.alive?(cache), do: cache
  end

  defp active_cache(_cache), do: nil

  defp normalize_roots(roots) when is_binary(roots), do: [Path.expand(roots)]

  defp normalize_roots(roots) when is_list(roots),
    do: Enum.map(roots, &Path.expand(to_string(&1)))

  defp normalize_roots(root), do: [Path.expand(to_string(root))]

  defmodule ReloadCache do
    @moduledoc false

    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    def lookup(cache, cache_key, metadata_key),
      do: GenServer.call(cache, {:lookup, cache_key, metadata_key})

    def put(cache, cache_key, metadata_key, provider),
      do: GenServer.call(cache, {:put, cache_key, metadata_key, provider})

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call({:lookup, cache_key, metadata_key}, _from, state) do
      reply =
        case Map.get(state, cache_key) do
          {^metadata_key, provider} -> {:ok, provider}
          _other -> :error
        end

      {:reply, reply, state}
    end

    def handle_call({:put, cache_key, metadata_key, provider}, _from, state) do
      {:reply, :ok, Map.put(state, cache_key, {metadata_key, provider})}
    end
  end
end
