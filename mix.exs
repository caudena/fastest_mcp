defmodule FastestMCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :fastest_mcp,
      version: "1.0.0",
      description:
        "Production-grade Model Context Protocol (MCP) SDK for Elixir and Phoenix. FastestMCP is an idiomatic Elixir rewrite of Python's FastMCP (fast_mcp), with server and client support for MCP 2026-07-28 and 2025-11-25, OAuth, MCP Apps, Tasks, Streamable HTTP, stdio, strict validation, and observability.",
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
      {:jsv, "~> 0.26.0"},
      {:mint, "~> 1.9"},
      {:opentelemetry, "~> 1.6", only: :test},
      {:opentelemetry_api, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"},
      {:texture, "~> 2.0"},
      {:yamerl, "~> 0.10.0"}
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
        "README.md",
        "docs/getting-started.md",
        "docs/concepts.md",
        "docs/tools.md",
        "docs/resources.md",
        "docs/prompts.md",
        "docs/context.md",
        "docs/lifespans-and-dependencies.md",
        "docs/sampling-and-elicitation.md",
        "docs/background-tasks.md",
        "docs/auth.md",
        "docs/phoenix.md",
        "docs/transports.md",
        "docs/testing.md",
        "docs/observability.md",
        "docs/production.md",
        "docs/troubleshooting.md",
        "docs/client.md",
        "docs/client-callbacks.md",
        "docs/client-auth.md",
        "docs/middleware.md",
        "docs/providers-and-mounting.md",
        "docs/transforms.md",
        "docs/versioning-and-visibility.md",
        "docs/dynamic-components.md",
        "docs/extensions.md",
        "docs/protocol-versions.md",
        "docs/pagination.md",
        "docs/schema-validation.md",
        "docs/compatibility-and-scope.md",
        "docs/migrating-to-1.0.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        "Start Here": [
          "README.md",
          "docs/getting-started.md",
          "docs/concepts.md"
        ],
        "Build Servers": [
          "docs/tools.md",
          "docs/resources.md",
          "docs/prompts.md",
          "docs/context.md",
          "docs/lifespans-and-dependencies.md",
          "docs/sampling-and-elicitation.md",
          "docs/background-tasks.md",
          "docs/auth.md"
        ],
        "Phoenix and HTTP": [
          "docs/phoenix.md",
          "docs/transports.md",
          "docs/testing.md"
        ],
        Operations: [
          "docs/observability.md",
          "docs/production.md",
          "docs/troubleshooting.md"
        ],
        Client: [
          "docs/client.md",
          "docs/client-callbacks.md",
          "docs/client-auth.md"
        ],
        Advanced: [
          "docs/middleware.md",
          "docs/providers-and-mounting.md",
          "docs/transforms.md",
          "docs/versioning-and-visibility.md",
          "docs/dynamic-components.md",
          "docs/extensions.md"
        ],
        Reference: [
          "docs/protocol-versions.md",
          "docs/pagination.md",
          "docs/schema-validation.md",
          "docs/compatibility-and-scope.md",
          "docs/migrating-to-1.0.md",
          "CHANGELOG.md"
        ]
      ],
      groups_for_modules: module_groups,
      skip_code_autolink_to: [
        "FastestMCP.HTTP.request/3",
        "FastestMCP.Pagination.default_key/1"
      ],
      # Guides merged into others when the documentation was reorganized.
      redirects: %{
        "onboarding" => "getting-started",
        "why-fastest-mcp" => "concepts",
        "components" => "concepts",
        "lifespan" => "lifespans-and-dependencies",
        "dependency-injection" => "lifespans-and-dependencies",
        "component-manager" => "dynamic-components",
        "progress" => "context",
        "logging" => "observability",
        "telemetry" => "observability",
        "runtime-state-and-storage" => "production",
        "phoenix-deployment" => "phoenix",
        "sampling-and-interaction" => "sampling-and-elicitation"
      },
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
        FastestMCP.Progress,
        FastestMCP.Elicitation.Accepted,
        FastestMCP.Elicitation.Declined,
        FastestMCP.Elicitation.Cancelled,
        FastestMCP.ApplicationSession,
        FastestMCP.Apps,
        FastestMCP.InputRequiredResult,
        FastestMCP.RequestContext,
        FastestMCP.BackgroundTask,
        FastestMCP.TaskRecord,
        FastestMCP.PeerTask,
        FastestMCP.Root
      ],
      "Client and Transport": [
        FastestMCP.Client,
        FastestMCP.ClientGroup,
        FastestMCP.Client.CallbackContext,
        FastestMCP.Client.Info,
        FastestMCP.Client.OAuth,
        FastestMCP.Client.OAuth.AuthorizationHandler,
        FastestMCP.Client.OAuth.AuthorizationHandler.Request,
        FastestMCP.Client.OAuth.ClientAssertionProvider,
        FastestMCP.Client.OAuth.ClientAssertionProvider.Request,
        FastestMCP.Client.OAuth.EnterpriseManagedProvider,
        FastestMCP.Client.OAuth.EnterpriseManagedProvider.Request,
        FastestMCP.Client.OAuth.EnterpriseManagedProvider.Assertion,
        FastestMCP.Client.OAuth.Error,
        FastestMCP.Client.OAuth.TokenStore,
        FastestMCP.Client.OAuth.TokenStore.Memory,
        FastestMCP.Client.ProtocolError,
        FastestMCP.Client.Request,
        FastestMCP.Client.Task,
        FastestMCP.Client.ToolResult,
        FastestMCP.Client.ToolResultRequest,
        FastestMCP.Client.URLElicitation,
        FastestMCP.Protocol,
        FastestMCP.Protocol.Extensions,
        FastestMCP.Transport.HTTPApp,
        FastestMCP.Transport.WellKnownHTTP,
        FastestMCP.Transport.StreamableHTTP,
        FastestMCP.Transport.Stdio
      ],
      "Runtime Features": [
        FastestMCP.Auth,
        FastestMCP.Auth.ProtectedResource,
        FastestMCP.Auth.Result,
        FastestMCP.Auth.StaticToken,
        FastestMCP.Authorization,
        FastestMCP.Authorization.Check,
        FastestMCP.Authorization.Context,
        FastestMCP.ComponentManager,
        FastestMCP.Error,
        FastestMCP.Interact,
        FastestMCP.Middleware,
        FastestMCP.Middleware.ToolSearch,
        FastestMCP.Operation,
        FastestMCP.Provider,
        FastestMCP.ProviderTransform,
        FastestMCP.ProviderTransforms.Namespace,
        FastestMCP.ProviderTransforms.ToolTransform,
        FastestMCP.Providers.ApplicationSessions,
        FastestMCP.Providers.Local,
        FastestMCP.Providers.MountedServer,
        FastestMCP.Providers.Proxy,
        FastestMCP.Providers.Skills,
        FastestMCP.Providers.SkillsDirectory,
        FastestMCP.ResourceSecurity,
        FastestMCP.ServerExtension,
        FastestMCP.ServerExtension.Method,
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
        FastestMCP.Components.Tool,
        FastestMCP.Components.Resource,
        FastestMCP.Components.ResourceTemplate,
        FastestMCP.Components.Prompt,
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
        "Documentation" => "https://hexdocs.pm/fastest_mcp",
        "GitHub" => "https://github.com/caudena/fastest_mcp",
        "Changelog" => "https://github.com/caudena/fastest_mcp/blob/master/CHANGELOG.md"
      }
    ]
  end
end
