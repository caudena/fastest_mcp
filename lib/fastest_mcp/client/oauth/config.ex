defmodule FastestMCP.Client.OAuth.Config do
  @moduledoc false
  # Validated OAuth coordinator options, built in the caller before the
  # coordinator starts. An unknown or duplicate option raises `ArgumentError`
  # (without printing values, which may be secrets); an invalid value is a
  # `:configuration` error. The pre-registered client of the authorization-code
  # and enterprise grants is validated when a flow uses it, so its errors carry
  # the `:client_registration` stage.

  import FastestMCP.Util, only: [stringify_keys: 1]

  alias FastestMCP.Client.OAuth.Error
  alias FastestMCP.Client.OAuth.URL
  alias FastestMCP.Options
  alias FastestMCP.URIPolicy

  defstruct [
    :grant,
    :registration,
    :redirect_uri,
    :authorization_handler,
    :application_type,
    :provider,
    :authorization_server,
    :requester,
    :token_store,
    :credential_listener,
    scopes: [],
    timeout_ms: 5_000,
    max_body_bytes: 1_048_576
  ]

  @type t :: %__MODULE__{grant: :authorization_code | :client_credentials | :enterprise_managed}

  @options ~w(grant redirect_uri registration authorization_handler application_type provider
              authorization_server token_store requester credential_listener scopes timeout_ms
              max_body_bytes)a

  @auth_methods ~w(none client_secret_basic client_secret_post private_key_jwt)

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) do
    opts = Options.keys!(opts, @options)
    listener = opts[:credential_listener]
    requester = opts[:requester]
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, 1_048_576)

    with :ok <- check(is_nil(listener) or is_pid(listener), :invalid_credential_listener),
         {:ok, grant} <- grant(opts[:grant], opts),
         {:ok, authorization_server} <- optional(opts[:authorization_server], &URL.exact_https/1),
         {:ok, scopes} <- scopes(Keyword.get(opts, :scopes, [])),
         :ok <-
           check(positive?(timeout_ms) and positive?(max_body_bytes), :positive_integer_required),
         :ok <- check(is_nil(requester) or is_function(requester, 3), :invalid_requester),
         :ok <- check(token_store?(opts[:token_store]), :invalid_token_store) do
      config = %__MODULE__{
        authorization_server: authorization_server,
        scopes: scopes,
        requester: requester,
        token_store: opts[:token_store],
        credential_listener: listener,
        timeout_ms: timeout_ms,
        max_body_bytes: max_body_bytes
      }

      {:ok, struct!(config, grant)}
    else
      {:error, reason} -> {:error, Error.exception(stage: :configuration, reason: reason)}
    end
  end

  # A registered client: its id and how it authenticates at the token endpoint.
  def client(client) when is_list(client), do: client |> Map.new() |> client()

  def client(client) when is_map(client) do
    client = stringify_keys(client)
    method = auth_method(client["token_endpoint_auth_method"])
    secret = client["client_secret"]
    provider = client["assertion_provider"]
    secret? = method not in ~w(client_secret_basic client_secret_post) or present?(secret)
    assertion? = method != "private_key_jwt" or callback?(provider, :assertion)

    with :ok <- check(present?(client["client_id"]), :client_id_required),
         :ok <- check(method in @auth_methods, :unsupported_token_endpoint_auth_method),
         :ok <- check(secret?, :client_secret_required),
         :ok <- check(assertion?, :client_assertion_provider_required),
         {:ok, issuer} <- optional(client["issuer"], &URL.exact_https/1) do
      {:ok,
       %{
         client_id: client["client_id"],
         client_secret: secret,
         token_endpoint_auth_method: method,
         assertion_provider: provider,
         issuer: issuer
       }}
    end
  end

  def client(_client), do: {:error, :invalid_client_registration}

  # A host callback: an arity-one function or a module exporting `name/1`.
  defp callback?(fun, _name) when is_function(fun, 1), do: true

  defp callback?(module, name) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, 1)

  defp callback?(_value, _name), do: false

  def invoke(fun, _name, argument) when is_function(fun, 1), do: fun.(argument)
  def invoke(module, name, argument), do: apply(module, name, [argument])

  defp grant(grant, opts) when grant in [nil, :authorization_code],
    do: grant({:authorization_code, []}, opts)

  defp grant({:authorization_code, grant_opts}, opts)
       when is_list(grant_opts) or is_map(grant_opts) do
    value = lookup(grant_opts, opts)

    with {:ok, redirect_uri} <- URL.redirect_uri(value.(:redirect_uri)),
         {:ok, registration} <- registration(value.(:registration)),
         {:ok, handler} <- authorization_handler(value.(:authorization_handler)),
         {:ok, application_type} <- application_type(value.(:application_type), redirect_uri) do
      {:ok,
       [
         grant: :authorization_code,
         redirect_uri: redirect_uri,
         registration: registration,
         authorization_handler: handler,
         application_type: application_type
       ]}
    end
  end

  defp grant({:client_credentials, client}, _opts) when is_list(client) or is_map(client) do
    case client(client) do
      {:ok, %{token_endpoint_auth_method: method} = client}
      when method in ["client_secret_basic", "private_key_jwt"] ->
        {:ok, [grant: :client_credentials, registration: {:pre_registered, client}]}

      {:ok, _client} ->
        {:error, :client_credentials_auth_method_required}

      error ->
        error
    end
  end

  defp grant({:enterprise_managed, grant_opts}, opts)
       when is_list(grant_opts) or is_map(grant_opts) do
    value = lookup(grant_opts, opts)
    provider = value.(:provider)

    case registration(value.(:registration)) do
      {:ok, {:dynamic, _metadata}} ->
        {:error, :dynamic_registration_not_supported_for_enterprise_managed}

      {:ok, registration} ->
        if callback?(provider, :identity_assertion),
          do: {:ok, [grant: :enterprise_managed, registration: registration, provider: provider]},
          else: {:error, :enterprise_identity_provider_required}

      error ->
        error
    end
  end

  defp grant(_grant, _opts), do: {:error, :invalid_oauth_grant}

  # A grant option overrides the top-level option of the same name.
  defp lookup(grant_opts, opts) do
    grant_opts = grant_opts |> Map.new() |> stringify_keys()
    fn key -> grant_opts[Atom.to_string(key)] || opts[key] end
  end

  defp registration({:pre_registered, client} = registration)
       when is_list(client) or is_map(client),
       do: {:ok, registration}

  defp registration({:client_metadata_document, url} = registration) when is_binary(url),
    do: {:ok, registration}

  defp registration({:dynamic, metadata}) when is_list(metadata) or is_map(metadata),
    do: {:ok, {:dynamic, Map.new(metadata)}}

  defp registration(_registration), do: {:error, :registration_required}

  defp authorization_handler(handler) do
    cond do
      callback?(handler, :authorize) -> {:ok, handler}
      is_atom(handler) -> {:error, :invalid_authorization_handler}
      true -> {:error, :authorization_handler_required}
    end
  end

  # Dynamic registration sends `native` for a loopback redirect.
  defp application_type(nil, redirect_uri) do
    if URIPolicy.loopback_host?(URI.parse(redirect_uri).host),
      do: {:ok, "native"},
      else: {:ok, "web"}
  end

  defp application_type(type, _redirect_uri) when type in ["native", "web"], do: {:ok, type}
  defp application_type(_type, _redirect_uri), do: {:error, :invalid_application_type}

  defp scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &(present?(&1) and not String.match?(&1, ~r/\s/))),
      do: {:ok, Enum.uniq(scopes)},
      else: {:error, :invalid_scopes}
  end

  defp scopes(_scopes), do: {:error, :invalid_scopes}

  defp token_store?(nil), do: true

  defp token_store?({module, _store}) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?([get: 2, put: 3, delete: 2], fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
  end

  defp token_store?(_store), do: false

  defp auth_method(nil), do: "none"
  defp auth_method(method) when is_atom(method), do: Atom.to_string(method)
  defp auth_method(method), do: method

  defp optional(nil, _validate), do: {:ok, nil}
  defp optional(value, validate), do: validate.(value)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp present?(value), do: is_binary(value) and value != ""
  defp positive?(value), do: is_integer(value) and value > 0
end
