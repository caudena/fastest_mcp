defmodule FastestMCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :fastest_mcp,
      version: "0.2.0",
      description:
        "BEAM-native MCP toolkit for supervised Elixir servers, clients, auth, and transports",
      source_url: "https://github.com/caudena/fastest_mcp",
      homepage_url: "https://github.com/caudena/fastest_mcp",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :ssl],
      mod: {FastestMCP.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:jsv, "~> 0.21.2"},
      {:mint, "~> 1.9"},
      {:opentelemetry, "~> 1.6", only: :test},
      {:opentelemetry_api, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"},
      {:texture, "~> 1.2"}
    ]
  end

  defp docs do
    module_groups = module_groups()
    public_modules = Enum.flat_map(module_groups, fn {_group, modules} -> modules end)

    [
      main: "readme",
      source_ref: "master",
      source_url: "https://github.com/caudena/fastest_mcp",
      assets: %{
        "docs/assets" => "."
      },
      extras: [
        "CHANGELOG.md",
        "README.md",
        "docs/onboarding.md",
        "docs/why-fastest-mcp.md",
        "docs/components.md",
        "docs/tools.md",
        "docs/resources.md",
        "docs/prompts.md",
        "docs/context.md",
        "docs/dependency-injection.md",
        "docs/lifespan.md",
        "docs/transports.md",
        "docs/client.md",
        "docs/sampling-and-interaction.md",
        "docs/pagination.md",
        "docs/progress.md",
        "docs/logging.md",
        "docs/telemetry.md",
        "docs/component-manager.md",
        "docs/auth.md",
        "docs/middleware.md",
        "docs/background-tasks.md",
        "docs/providers-and-mounting.md",
        "docs/transforms.md",
        "docs/versioning-and-visibility.md",
        "docs/testing.md",
        "docs/runtime-state-and-storage.md",
        "docs/schema-validation.md",
        "docs/compatibility-and-scope.md"
      ],
      groups_for_extras: [
        "Start Here": ["README.md", "CHANGELOG.md", "docs/onboarding.md"],
        Explanation: [
          "docs/why-fastest-mcp.md",
          "docs/compatibility-and-scope.md"
        ],
        Features: [
          "docs/components.md",
          "docs/tools.md",
          "docs/resources.md",
          "docs/prompts.md",
          "docs/context.md",
          "docs/dependency-injection.md",
          "docs/lifespan.md",
          "docs/transports.md",
          "docs/client.md",
          "docs/sampling-and-interaction.md",
          "docs/pagination.md",
          "docs/progress.md",
          "docs/logging.md",
          "docs/telemetry.md",
          "docs/component-manager.md",
          "docs/auth.md",
          "docs/middleware.md",
          "docs/background-tasks.md",
          "docs/providers-and-mounting.md",
          "docs/transforms.md",
          "docs/versioning-and-visibility.md",
          "docs/testing.md",
          "docs/runtime-state-and-storage.md",
          "docs/schema-validation.md"
        ]
      ],
      groups_for_modules: module_groups,
      skip_code_autolink_to: [
        "FastestMCP.BackgroundTaskStore",
        "FastestMCP.Client.Task",
        "FastestMCP.EventBus",
        "FastestMCP.HTTP.request/3",
        "FastestMCP.OperationPipeline",
        "FastestMCP.Pagination.default_key/1",
        "FastestMCP.Session",
        "FastestMCP.Session.verify_identity/3",
        "FastestMCP.Transport.HTTPCommon",
        "FastestMCP.Transport.JSONRPC"
      ],
      filter_modules: fn module, _metadata -> module in public_modules end
    ]
  end

  defp module_groups do
    [
      "Core API": [
        FastestMCP,
        FastestMCP.Lifespan,
        FastestMCP.ServerModule,
        FastestMCP.Server,
        FastestMCP.Context,
        FastestMCP.RequestContext,
        FastestMCP.BackgroundTask,
        FastestMCP.PeerTask,
        FastestMCP.Root
      ],
      "Client and Transport": [
        FastestMCP.Client,
        FastestMCP.Client.CallbackContext,
        FastestMCP.Client.OAuth,
        FastestMCP.Client.OAuth.AuthorizationHandler,
        FastestMCP.Client.OAuth.AuthorizationHandler.Request,
        FastestMCP.Client.OAuth.Error,
        FastestMCP.Client.OAuth.TokenStore,
        FastestMCP.Client.OAuth.TokenStore.Memory,
        FastestMCP.Client.ProtocolError,
        FastestMCP.Client.Request,
        FastestMCP.Client.Task,
        FastestMCP.Client.URLElicitation,
        FastestMCP.Protocol,
        FastestMCP.Transport.HTTPApp,
        FastestMCP.Transport.StreamableHTTP,
        FastestMCP.Transport.Stdio
      ],
      "Runtime Features": [
        FastestMCP.Auth,
        FastestMCP.Auth.ProtectedResource,
        FastestMCP.Auth.Result,
        FastestMCP.Auth.StaticToken,
        FastestMCP.ComponentManager,
        FastestMCP.Error,
        FastestMCP.Interact,
        FastestMCP.Middleware,
        FastestMCP.Operation,
        FastestMCP.Provider,
        FastestMCP.Sampling,
        FastestMCP.Schema,
        FastestMCP.Schema.Compiled,
        FastestMCP.Schema.Error,
        FastestMCP.Schema.HTTPResolver,
        FastestMCP.SessionStateStore,
        FastestMCP.SessionStateStore.Memory,
        FastestMCP.TaskBackend,
        FastestMCP.TaskBackend.Memory
      ],
      "Prompt, Resource, and Tool Helpers": [
        FastestMCP.Tools.Result,
        FastestMCP.Prompts.Message,
        FastestMCP.Prompts.Result,
        FastestMCP.Resources.Binary,
        FastestMCP.Resources.Content,
        FastestMCP.Resources.Directory,
        FastestMCP.Resources.File,
        FastestMCP.Resources.HTTP,
        FastestMCP.Resources.Result,
        FastestMCP.Resources.Text
      ]
    ]
  end

  defp package do
    [
      name: "fastest_mcp",
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "config",
        "docs",
        "lib",
        "mix.exs",
        "priv"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/caudena/fastest_mcp"
      }
    ]
  end
end
