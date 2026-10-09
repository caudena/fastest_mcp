{:ok, _} = Application.ensure_all_started(:opentelemetry)

# A generous default for assert_receive keeps tests stable on a loaded machine;
# it only delays failures.
ExUnit.start(exclude: [:conformance, :external_auth, :interop], assert_receive_timeout: 1_000)
