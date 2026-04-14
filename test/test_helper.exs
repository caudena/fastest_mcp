{:ok, _} = Application.ensure_all_started(:opentelemetry)

ExUnit.start(exclude: [:conformance, :external_auth])
