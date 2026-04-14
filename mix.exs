defmodule FastestMCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :fastest_mcp,
      version: "0.1.0",
      description: "BEAM-native MCP toolkit for Elixir applications",
      source_url: "https://github.com/caudena/FastestMCP",
      homepage_url: "https://github.com/caudena/FastestMCP",
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
      {:assent, "~> 0.3"},
      {:bandit, "~> 1.5"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:opentelemetry, "~> 1.6", only: :test},
      {:opentelemetry_api, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp docs do
    public_modules = public_modules()

    [
      main: "readme",
      source_ref: "master",
      source_url: "https://github.com/caudena/FastestMCP",
      assets: %{
        "docs/assets" => "."
      },
      extras: [
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
        "docs/compatibility-and-scope.md"
      ],
      groups_for_extras: [
        "Start Here": ["README.md", "docs/onboarding.md"],
        Explanation: ["docs/why-fastest-mcp.md", "docs/compatibility-and-scope.md"],
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
          "docs/runtime-state-and-storage.md"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          FastestMCP,
          FastestMCP.Lifespan,
          FastestMCP.ServerModule,
          FastestMCP.Server,
          FastestMCP.Context,
          FastestMCP.RequestContext,
          FastestMCP.BackgroundTask
        ],
        "Client and Transport": [
          FastestMCP.Client,
          FastestMCP.Protocol,
          FastestMCP.Transport.HTTPApp,
          FastestMCP.Transport.StreamableHTTP,
          FastestMCP.Transport.Stdio
        ],
        "Runtime Features": [
          FastestMCP.Auth,
          FastestMCP.ComponentManager,
          FastestMCP.Error,
          FastestMCP.Interact,
          FastestMCP.Middleware,
          FastestMCP.Operation,
          FastestMCP.Provider,
          FastestMCP.Sampling,
          FastestMCP.SessionStateStore,
          FastestMCP.SessionStateStore.Memory
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
      ],
      filter_modules: fn module, _metadata -> module in public_modules end
    ]
  end

  defp package do
    [
      name: "fastest_mcp",
      files: [
        ".formatter.exs",
        "LICENSE",
        "README.md",
        "config",
        "docs",
        "lib",
        "mix.exs"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/caudena/FastestMCP"
      }
    ]
  end

  defp public_modules do
    [
      FastestMCP,
      FastestMCP.Auth,
      FastestMCP.BackgroundTask,
      FastestMCP.Client,
      FastestMCP.ComponentManager,
      FastestMCP.Context,
      FastestMCP.Error,
      FastestMCP.Interact,
      FastestMCP.Lifespan,
      FastestMCP.Middleware,
      FastestMCP.Operation,
      FastestMCP.Protocol,
      FastestMCP.Prompts.Message,
      FastestMCP.Prompts.Result,
      FastestMCP.Provider,
      FastestMCP.RequestContext,
      FastestMCP.Resources.Binary,
      FastestMCP.Resources.Content,
      FastestMCP.Resources.Directory,
      FastestMCP.Resources.File,
      FastestMCP.Resources.HTTP,
      FastestMCP.Resources.Result,
      FastestMCP.Resources.Text,
      FastestMCP.Sampling,
      FastestMCP.Server,
      FastestMCP.ServerModule,
      FastestMCP.SessionStateStore,
      FastestMCP.SessionStateStore.Memory,
      FastestMCP.Tools.Result,
      FastestMCP.Transport.HTTPApp,
      FastestMCP.Transport.StreamableHTTP,
      FastestMCP.Transport.Stdio
    ]
  end
end
