import Config

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none,
  create_application_tracers: false

config :fastest_mcp, jwt_kdf_iterations: 10
