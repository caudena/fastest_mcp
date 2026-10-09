defmodule FastestMCP.Middleware.ToolInjection do
  @moduledoc false
  # Injected tools are listed ahead of registered tools and resolved before the
  # registry, so they override base tools of the same name.

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [:middleware, tools: [], tools_by_name: %{}]

  @type injected_tool ::
          FastestMCP.Components.Tool.t()
          | {String.t() | atom(), function()}
          | {String.t() | atom(), function(), keyword()}

  @type t :: %__MODULE__{
          tools: [FastestMCP.Components.Tool.t()],
          tools_by_name: %{optional(String.t()) => FastestMCP.Components.Tool.t()}
        }

  def new(tools, opts \\ []) do
    normalized =
      tools
      |> List.wrap()
      |> Enum.map(&normalize_tool(&1, opts))
      |> deduplicate_tools()

    middleware = %__MODULE__{
      tools: normalized,
      tools_by_name: Map.new(normalized, fn tool -> {tool.name, tool} end)
    }

    middleware
  end

  def prompt_tools(opts \\ []) do
    new(
      [
        {"list_prompts", &list_prompts_tool/2,
         [description: "List prompts available on this server."]},
        {"get_prompt", &get_prompt_tool/2,
         [description: "Render a prompt available on this server."]}
      ],
      opts
    )
  end

  def resource_tools(opts \\ []) do
    new(
      [
        {"list_resources", &list_resources_tool/2,
         [description: "List resources and resource templates available on this server."]},
        {"read_resource", &read_resource_tool/2,
         [description: "Read a resource available on this server."]}
      ],
      opts
    )
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{method: "tools/list"} = operation, next)
      when is_function(next, 1) do
    visible_tools = visible_tools(middleware, operation)
    visible_names = MapSet.new(visible_tools, & &1.name)

    operation
    |> next.()
    |> Middleware.map_result(fn base_tools ->
      Enum.map(visible_tools, &Component.metadata/1) ++
        Enum.reject(List.wrap(base_tools), &MapSet.member?(visible_names, listed_tool_name(&1)))
    end)
  end

  def call(
        %__MODULE__{} = middleware,
        %Operation{method: "tools/call", target: target} = operation,
        next
      )
      when is_function(next, 1) do
    case prepare_tool(middleware, target, operation) do
      {:ok, visible_tool} -> execute_tool(visible_tool, operation)
      {:error, %Error{}} = error -> error
      _hidden_or_missing -> next.(operation)
    end
  end

  def call(_middleware, %Operation{} = operation, next) when is_function(next, 1) do
    next.(operation)
  end

  def visible_tools(%__MODULE__{} = middleware, %Operation{} = operation) do
    apply_list_policy(middleware.tools, operation)
  end

  def tool_names(%__MODULE__{} = middleware), do: Enum.map(middleware.tools, & &1.name)

  def prepare_tool(%__MODULE__{} = middleware, target, %Operation{} = operation) do
    case Map.fetch(middleware.tools_by_name, to_string(target)) do
      {:ok, tool} ->
        case ComponentPolicy.apply_result(operation.context.server, tool, operation) do
          {:ok, visible_tool} ->
            {:ok, visible_tool}

          {:error, %Error{code: code}} when code in [:disabled, :filtered, :not_visible] ->
            :hidden

          {:error, %Error{} = error} ->
            {:error, error}
        end

      :error ->
        :not_found
    end
  end

  defp execute_tool(tool, %Operation{} = operation) do
    operation = %{operation | component: tool}
    FastestMCP.Telemetry.annotate_span(operation)

    with {:ok, result} <- Component.execute(tool, operation),
         do: {:ok, %{operation | result: result}}
  end

  defp normalize_tool(%FastestMCP.Components.Tool{} = tool, _opts), do: tool

  defp normalize_tool({name, handler}, opts) do
    normalize_tool({name, handler, []}, opts)
  end

  defp normalize_tool({name, handler, tool_opts}, opts) do
    ComponentCompiler.compile(
      :tool,
      name,
      handler,
      Keyword.merge(opts, tool_opts)
    )
  end

  defp normalize_tool(other, _opts) do
    raise ArgumentError,
          "tool injection entries must be compiled tools or {name, handler[, opts]} tuples, got #{inspect(other)}"
  end

  defp deduplicate_tools(tools) do
    {names, tools_by_name} =
      Enum.reduce(tools, {[], %{}}, fn tool, {names, tools_by_name} ->
        if Map.has_key?(tools_by_name, tool.name) do
          {names, Map.put(tools_by_name, tool.name, tool)}
        else
          {[tool.name | names], Map.put(tools_by_name, tool.name, tool)}
        end
      end)

    names
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(tools_by_name, &1))
  end

  defp apply_list_policy(tools, operation) do
    Enum.reduce(tools, [], fn tool, visible ->
      case ComponentPolicy.apply_result(operation.context.server, tool, operation) do
        {:ok, visible_tool} -> [visible_tool | visible]
        {:error, %Error{}} -> visible
      end
    end)
    |> Enum.reverse()
  end

  # Listed tools are `Component.metadata/1` maps.
  defp listed_tool_name(tool) when is_map(tool), do: to_string(Map.get(tool, :name))

  defp list_prompts_tool(_arguments, context) do
    %{"prompts" => FastestMCP.list_prompts!(context.server_name, inherited_opts(context))}
  end

  defp get_prompt_tool(arguments, context) do
    %{
      "result" =>
        FastestMCP.render_prompt!(
          context.server_name,
          Map.fetch!(arguments, "name"),
          Map.get(arguments, "arguments", %{}),
          inherited_opts(context)
        )
        |> FastestMCP.Prompts.Result.to_map()
    }
  end

  defp list_resources_tool(_arguments, context) do
    %{
      "resources" => FastestMCP.list_resources!(context.server_name, inherited_opts(context)),
      "resource_templates" =>
        FastestMCP.list_resource_templates!(context.server_name, inherited_opts(context))
    }
  end

  defp read_resource_tool(arguments, context) do
    %{
      "result" =>
        FastestMCP.read_resource!(
          context.server_name,
          Map.fetch!(arguments, "uri"),
          inherited_opts(context)
        )
    }
  end

  defp inherited_opts(context) do
    [
      session_id: Map.get(context, :session_id),
      transport: Map.get(context, :transport, :in_process),
      request_metadata: Map.get(context, :request_metadata, %{}),
      principal: Map.get(context, :principal),
      authenticated: Map.get(context, :authenticated, false),
      auth: Map.get(context, :auth, %{}),
      capabilities: Map.get(context, :capabilities, []),
      verified_audiences: Map.get(context, :verified_audiences, []),
      verified_scopes: Map.get(context, :verified_scopes, []),
      transport_authenticated: Map.get(context, :authenticated, false),
      task_metadata: Map.get(context, :task_metadata, %{})
    ]
  end
end
