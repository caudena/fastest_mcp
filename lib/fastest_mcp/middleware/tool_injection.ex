defmodule FastestMCP.Middleware.ToolInjection do
  @moduledoc """
  Middleware that injects synthetic tools into the shared operation pipeline.
  Injected tools are listed ahead of registered tools and are executed before
  normal registry lookup, so they can override base tools when names collide.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Operation

  defstruct [:middleware, tools: [], tools_by_name: %{}]

  @type injected_tool ::
          FastestMCP.Components.Tool.t()
          | {String.t() | atom(), function()}
          | {String.t() | atom(), function(), keyword()}

  @type t :: %__MODULE__{
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          tools: [FastestMCP.Components.Tool.t()],
          tools_by_name: %{optional(String.t()) => FastestMCP.Components.Tool.t()}
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(tools, opts \\ []) do
    normalized =
      tools
      |> List.wrap()
      |> Enum.map(&normalize_tool(&1, opts))

    middleware = %__MODULE__{
      tools: normalized,
      tools_by_name: Map.new(normalized, fn tool -> {tool.name, tool} end)
    }

    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  @doc "Builds the synthetic prompt-tool set used by tool injection."
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

  @doc "Builds the synthetic resource-tool set used by tool injection."
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

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{method: "tools/list"} = operation, next)
      when is_function(next, 1) do
    Enum.map(middleware.tools, &Component.metadata/1) ++ List.wrap(next.(operation))
  end

  def call(
        %__MODULE__{} = middleware,
        %Operation{method: "tools/call", target: target} = operation,
        next
      )
      when is_function(next, 1) do
    case Map.fetch(middleware.tools_by_name, to_string(target)) do
      {:ok, tool} ->
        operation = %{operation | component: tool}
        FastestMCP.Telemetry.annotate_span(operation)
        Component.execute(tool, operation)

      :error ->
        next.(operation)
    end
  end

  def call(_middleware, %Operation{} = operation, next) when is_function(next, 1) do
    next.(operation)
  end

  defp normalize_tool(%FastestMCP.Components.Tool{} = tool, _opts), do: tool

  defp normalize_tool({name, handler}, opts) do
    normalize_tool({name, handler, []}, opts)
  end

  defp normalize_tool({name, handler, tool_opts}, opts) do
    ComponentCompiler.compile(
      :tool,
      "__injected__",
      name,
      handler,
      Keyword.merge(opts, tool_opts)
    )
  end

  defp normalize_tool(other, _opts) do
    raise ArgumentError,
          "tool injection entries must be compiled tools or {name, handler[, opts]} tuples, got #{inspect(other)}"
  end

  defp list_prompts_tool(_arguments, context) do
    %{"prompts" => FastestMCP.list_prompts(context.server_name, inherited_opts(context))}
  end

  defp get_prompt_tool(arguments, context) do
    %{
      "result" =>
        FastestMCP.render_prompt(
          context.server_name,
          Map.fetch!(arguments, "name"),
          Map.get(arguments, "arguments", %{}),
          inherited_opts(context)
        )
    }
  end

  defp list_resources_tool(_arguments, context) do
    %{
      "resources" => FastestMCP.list_resources(context.server_name, inherited_opts(context)),
      "resource_templates" =>
        FastestMCP.list_resource_templates(context.server_name, inherited_opts(context))
    }
  end

  defp read_resource_tool(arguments, context) do
    %{
      "result" =>
        FastestMCP.read_resource(
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
      auth: Map.get(context, :auth, %{}),
      capabilities: Map.get(context, :capabilities, []),
      task_metadata: Map.get(context, :task_metadata, %{})
    ]
  end
end
