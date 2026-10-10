defmodule FastestMCP.DocsCodeTest do
  # Checks the README and guides as published: every Elixir example parses
  # and calls only public FastestMCP functions that exist, every local link
  # and heading anchor resolves, and every guide is listed in the ExDoc
  # extras.
  use ExUnit.Case, async: true

  @guides ["README.md" | Enum.sort(Path.wildcard("docs/*.md"))]

  test "every Elixir example parses without placeholders or prompts" do
    failures =
      for {file, line, code} <- elixir_blocks(),
          message <- parse_problems(code),
          do: "#{file}:#{line}: #{message}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "examples call only public FastestMCP functions that exist" do
    public = public_modules()

    failures =
      for {file, line, code} <- elixir_blocks(),
          {:ok, ast} <- [Code.string_to_quoted(code, line: line)],
          {kind, module, fun, arity, call_line} <- references(ast),
          message <- [reference_problem(kind, module, fun, arity, public)],
          message != nil,
          do: "#{file}:#{call_line || line}: #{message}"

    assert failures == [], Enum.join(Enum.uniq(failures), "\n")
  end

  test "local links and heading anchors resolve" do
    lib_docs = Path.wildcard("lib/**/*.ex")

    failures =
      for file <- @guides ++ lib_docs,
          link <- local_links(file),
          message <- [link_problem(file, link)],
          message != nil,
          do: "#{file}: #{message}"

    assert failures == [], Enum.join(failures, "\n")
  end

  # Complete files in the tutorial (blocks headed `# lib/my_app/...`) are
  # compiled from test/support/docs and exercised by the docs_examples tests.
  # Phoenix files (`lib/my_app_web/...`) cannot compile here.
  test "Getting Started files match their tested fixtures" do
    failures =
      for {"docs/getting-started.md" = file, line, code} <- elixir_blocks(),
          [_, path] <- [Regex.run(~r/\A# lib\/(\S+\.ex)\n/, code)],
          not String.contains?(path, "_web/"),
          fixture = Path.join("test/support/docs", path),
          message <- [fixture_problem(code, fixture)],
          message != nil,
          do: "#{file}:#{line}: #{message}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "every guide is published as an ExDoc extra" do
    extras =
      Mix.Project.config()[:docs][:extras]
      |> Enum.map(fn
        {path, _opts} -> to_string(path)
        path -> to_string(path)
      end)
      |> MapSet.new()

    assert MapSet.new(["CHANGELOG.md" | @guides]) == extras
  end

  defp fixture_problem(code, fixture) do
    cond do
      not File.exists?(fixture) ->
        "no tested fixture at #{fixture}"

      String.trim_trailing(File.read!(fixture)) != String.trim_trailing(code) ->
        "differs from #{fixture}"

      true ->
        nil
    end
  end

  ## Examples

  defp elixir_blocks do
    for file <- @guides, block <- fenced_blocks(file, "elixir"), do: block
  end

  defp fenced_blocks(file, language) do
    {blocks, _open} =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {text, number}, {blocks, open} ->
        trimmed = String.trim(text)

        cond do
          open == nil and String.starts_with?(trimmed, "```") ->
            info = trimmed |> String.trim_leading("`") |> String.trim()
            {blocks, if(info == language, do: {number + 1, []}, else: {:other, []})}

          open != nil and trimmed == "```" ->
            case open do
              {:other, _lines} ->
                {blocks, nil}

              {start, lines} ->
                {[{file, start, lines |> Enum.reverse() |> Enum.join("\n")} | blocks], nil}
            end

          open != nil ->
            {tag, lines} = open
            {blocks, {tag, [text | lines]}}

          true ->
            {blocks, open}
        end
      end)

    Enum.reverse(blocks)
  end

  defp parse_problems(code) do
    syntax =
      case Code.string_to_quoted(code) do
        {:ok, _ast} -> []
        {:error, {meta, message, token}} -> ["line #{meta[:line]}: #{inspect(message)} #{token}"]
      end

    lines = String.split(code, "\n")

    placeholders =
      for {text, index} <- Enum.with_index(lines, 1),
          String.contains?(code_part(text), "..."),
          do: "line #{index}: remove the `...` placeholder"

    prompts =
      for {text, index} <- Enum.with_index(lines, 1),
          Regex.match?(~r/^\s*iex(\(\d+\))?>/, text),
          do: "line #{index}: write code without `iex>` prompts"

    syntax ++ placeholders ++ prompts
  end

  # The part of a line before a comment, ignoring `#` inside strings.
  defp code_part(text) do
    text
    |> String.replace(~r/"(?:\\.|[^"\\])*"/, ~s(""))
    |> String.split("#", parts: 2)
    |> hd()
  end

  ## FastestMCP references

  defp public_modules do
    Mix.Project.config()[:docs][:groups_for_modules]
    |> Enum.flat_map(fn {_group, modules} -> modules end)
    |> MapSet.new()
  end

  # `{:call, module, fun, arity, line}` and `{:struct, module, nil, nil, line}`
  # for every FastestMCP module the example uses.
  defp references(ast) do
    {_ast, {references, _aliases}} =
      ast
      |> unpipe()
      |> Macro.prewalk({[], %{}}, &collect/2)

    references
    |> Enum.reverse()
    |> Enum.filter(fn {_kind, module, _fun, _arity, _line} -> fastest_mcp?(module) end)
  end

  defp unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _meta, [left, {call, meta, args}]} when is_list(args) -> {call, meta, [left | args]}
      node -> node
    end)
  end

  defp collect({:alias, _meta, [{:__aliases__, _, parts} | opts]} = node, {references, aliases}) do
    as =
      case opts do
        [[as: {:__aliases__, _, [name]}]] -> name
        _other -> List.last(parts)
      end

    {node, {references, Map.put(aliases, as, expand(parts, aliases))}}
  end

  # `alias FastestMCP.{A, B}`; the `{}` node is not a call, so it is not walked.
  defp collect(
         {:alias, _meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]},
         {references, aliases}
       ) do
    aliases =
      Enum.reduce(children, aliases, fn {:__aliases__, _, parts}, aliases ->
        Map.put(aliases, List.last(parts), expand(base, aliases) ++ parts)
      end)

    {:aliased, {references, aliases}}
  end

  # A capture names the arity explicitly; its inner call has no arguments.
  defp collect(
         {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, _}, arity]}]},
         {references, aliases}
       )
       when is_atom(fun) and is_integer(arity) do
    reference = {:call, module(parts, aliases), fun, arity, meta[:line]}
    {:captured, {[reference | references], aliases}}
  end

  defp collect(
         {{:., meta, [{:__aliases__, _, parts}, fun]}, _, args} = node,
         {references, aliases}
       )
       when is_atom(fun) and is_list(args) do
    reference = {:call, module(parts, aliases), fun, length(args), meta[:line]}
    {node, {[reference | references], aliases}}
  end

  defp collect({:%, meta, [{:__aliases__, _, parts}, _fields]} = node, {references, aliases}) do
    {node, {[{:struct, module(parts, aliases), nil, nil, meta[:line]} | references], aliases}}
  end

  defp collect(node, acc), do: {node, acc}

  defp expand([first | rest], aliases), do: Map.get(aliases, first, [first]) ++ rest

  defp module(parts, aliases), do: Module.concat(expand(parts, aliases))

  defp fastest_mcp?(module), do: hd(Module.split(module)) == "FastestMCP"

  defp reference_problem(:struct, module, _fun, _arity, public) do
    unless module in public, do: "#{inspect(module)} is not a documented module"
  end

  defp reference_problem(:call, module, fun, arity, public) do
    cond do
      module not in public ->
        "#{inspect(module)}.#{fun}/#{arity}: #{inspect(module)} is not a documented module"

      not (Code.ensure_loaded?(module) and
               (function_exported?(module, fun, arity) or macro_exported?(module, fun, arity))) ->
        "#{inspect(module)}.#{fun}/#{arity} does not exist"

      true ->
        nil
    end
  end

  ## Links and anchors

  defp local_links(file) do
    ~r/\]\(([^)\s]+)\)/
    |> Regex.scan(File.read!(file), capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&String.starts_with?(&1, ["http://", "https://", "mailto:"]))
    |> Enum.filter(&(String.contains?(&1, ".md") or String.starts_with?(&1, "#")))
  end

  defp link_problem(file, link) do
    {target, anchor} =
      case String.split(link, "#", parts: 2) do
        [target, anchor] -> {target, anchor}
        [target] -> {target, nil}
      end

    path = target_path(file, target)

    cond do
      path == nil and target == "" ->
        nil

      path == nil or not File.exists?(path) ->
        "#{inspect(link)} points to a missing file"

      anchor != nil and anchor not in heading_ids(path) ->
        "#{inspect(link)} points to a missing heading in #{path}"

      true ->
        nil
    end
  end

  # Guides link relative to themselves; module docs link guides by name.
  # A module doc's own `#module-...` sections are not guide headings.
  defp target_path(file, "") do
    unless String.ends_with?(file, ".ex"), do: file
  end

  defp target_path(file, target) do
    if String.ends_with?(file, ".ex"),
      do: Enum.find(["CHANGELOG.md" | @guides], &(Path.basename(&1) == Path.basename(target))),
      else: Path.relative_to_cwd(Path.expand(target, Path.dirname(file)))
  end

  # ExDoc's ids for `##` and `###` headings (`ExDoc.Utils.text_to_id/1`).
  defp heading_ids(path) do
    {ids, _seen, _fence} =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({[], %{}, false}, fn line, {ids, seen, fence} ->
        cond do
          String.starts_with?(String.trim(line), "```") ->
            {ids, seen, not fence}

          not fence and Regex.match?(~r/^###? /, line) ->
            id = line |> String.replace(~r/^###? /, "") |> heading_text() |> text_to_id()
            count = Map.get(seen, id, 0)
            id_with_count = if count >= 1, do: "#{id}-#{count}", else: id
            {[id_with_count | ids], Map.put(seen, id, count + 1), fence}

          true ->
            {ids, seen, fence}
        end
      end)

    ids
  end

  defp heading_text(markdown) do
    markdown
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/[`*_]/, "")
    |> String.trim()
  end

  defp text_to_id(text) do
    text
    |> String.replace(~r/&#\d+;/, "")
    |> String.replace(~r/&[A-Za-z0-9]+;/, "")
    |> String.replace(~r/\W+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end
end
