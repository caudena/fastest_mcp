defmodule FastestMCP.Elicitation.URL do
  @moduledoc false
  # Pure value rules of URL-mode elicitation; `FastestMCP.Session` holds the
  # mutable ownership and the atomic claim. Records are bound to the MCP session
  # and a server-verified principal, because a session ID is not a user identity.

  import FastestMCP.Util, only: [secure_equal?: 2]

  alias FastestMCP.Error
  alias FastestMCP.URIPolicy

  @default_ttl_ms 15 * 60 * 1_000
  @max_ttl_ms 24 * 60 * 60 * 1_000
  @max_url_bytes 8_192
  @max_message_bytes 4_096

  @sensitive_query_keys MapSet.new([
                          "access_token",
                          "api_key",
                          "apikey",
                          "authorization",
                          "credential",
                          "email",
                          "key",
                          "password",
                          "phone",
                          "secret",
                          "token",
                          "user",
                          "username"
                        ])

  @enforce_keys [
    :elicitation_id,
    :url,
    :message,
    :session_id,
    :principal_fingerprint,
    :inserted_at,
    :expires_at
  ]
  defstruct [
    :elicitation_id,
    :url,
    :message,
    :session_id,
    :principal_fingerprint,
    :inserted_at,
    :expires_at,
    :action,
    :responded_at,
    :completed_at,
    purpose: :external_interaction
  ]

  @type action :: :accept | :decline | :cancel
  @type purpose :: :external_authorization | :external_interaction | :payment | :sensitive_input

  @type t :: %__MODULE__{
          elicitation_id: String.t(),
          url: String.t(),
          message: String.t(),
          session_id: String.t(),
          principal_fingerprint: String.t(),
          inserted_at: integer(),
          expires_at: integer(),
          action: action() | nil,
          responded_at: integer() | nil,
          completed_at: integer() | nil,
          purpose: purpose()
        }

  def new(message, url_or_builder, opts) when is_list(opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    elicitation_id = Keyword.get_lazy(opts, :elicitation_id, &generate_id/0)

    with :ok <- validate_message(message),
         :ok <- validate_id(elicitation_id),
         {:ok, session_id} <- required_identity(opts, :session_id),
         {:ok, principal_fingerprint} <- required_identity(opts, :principal_fingerprint),
         {:ok, purpose} <- validate_purpose(Keyword.get(opts, :purpose, :external_interaction)),
         {:ok, ttl_ms} <- validate_ttl(Keyword.get(opts, :ttl_ms, @default_ttl_ms)),
         {:ok, allowed_hosts} <- normalize_allowed_hosts(Keyword.get(opts, :allowed_hosts)),
         {:ok, url} <- build_url(url_or_builder, elicitation_id),
         {:ok, canonical_url} <- validate_url(url, allowed_hosts) do
      {:ok,
       %__MODULE__{
         elicitation_id: elicitation_id,
         url: canonical_url,
         message: message,
         session_id: session_id,
         principal_fingerprint: principal_fingerprint,
         inserted_at: now_ms,
         expires_at: now_ms + ttl_ms,
         purpose: purpose
       }}
    end
  end

  def new!(message, url_or_builder, opts) do
    case new(message, url_or_builder, opts) do
      {:ok, elicitation} -> elicitation
      {:error, reason} -> raise ArgumentError, "invalid URL elicitation: #{format_reason(reason)}"
    end
  end

  def to_params(%__MODULE__{} = elicitation) do
    %{
      "mode" => "url",
      "elicitationId" => elicitation.elicitation_id,
      "url" => elicitation.url,
      "message" => elicitation.message
    }
  end

  def required_error_data(elicitations) when is_list(elicitations) and elicitations != [] do
    %{"elicitations" => Enum.map(elicitations, &to_params/1)}
  end

  def required_error(elicitations, message \\ "This request requires more information.")
      when is_binary(message) and message != "" do
    %Error{
      code: :url_elicitation_required,
      message: message,
      details: required_error_data(elicitations)
    }
  end

  def respond(elicitation, action, content \\ nil, now_ms \\ System.system_time(:millisecond))

  def respond(%__MODULE__{} = elicitation, action, content, now_ms) do
    with :ok <- ensure_active(elicitation, now_ms),
         {:ok, action} <- normalize_action(action),
         :ok <- ensure_url_content_absent(content),
         :ok <- ensure_response_transition(elicitation, action) do
      {:ok, %{elicitation | action: action, responded_at: now_ms}}
    end
  end

  def complete(
        %__MODULE__{} = elicitation,
        session_id,
        principal_fingerprint,
        now_ms \\ System.system_time(:millisecond)
      ) do
    with :ok <- ensure_binding(elicitation, session_id, principal_fingerprint),
         :ok <- ensure_active(elicitation, now_ms),
         :ok <- ensure_completable(elicitation) do
      {:ok, %{elicitation | completed_at: now_ms}}
    end
  end

  def expired?(%__MODULE__{expires_at: expires_at}, now_ms \\ System.system_time(:millisecond)),
    do: now_ms >= expires_at

  def validate_allowed_hosts(hosts) do
    case normalize_allowed_hosts(hosts) do
      {:ok, allowed_hosts} -> {:ok, allowed_hosts |> MapSet.to_list() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  def state(%__MODULE__{completed_at: completed_at}) when is_integer(completed_at), do: :completed
  def state(%__MODULE__{action: nil}), do: :pending
  def state(%__MODULE__{action: action}), do: action

  def completion_params(%__MODULE__{completed_at: completed_at, elicitation_id: id})
      when is_integer(completed_at),
      do: {:ok, %{"elicitationId" => id}}

  def completion_params(%__MODULE__{}), do: {:error, :not_completed}

  defp generate_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp validate_message(message)
       when is_binary(message) and byte_size(message) > 0 and
              byte_size(message) <= @max_message_bytes,
       do: :ok

  defp validate_message(_message), do: {:error, :invalid_message}

  defp validate_id(id) when is_binary(id) and byte_size(id) in 1..255 do
    if String.valid?(id) and not String.contains?(id, [<<0>>, "\r", "\n"]),
      do: :ok,
      else: {:error, :invalid_elicitation_id}
  end

  defp validate_id(_id), do: {:error, :invalid_elicitation_id}

  defp required_identity(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" and value != "anonymous" -> {:ok, value}
      _other -> {:error, {:missing_verified_identity, key}}
    end
  end

  defp validate_purpose(:mcp_authorization), do: {:error, :mcp_authorization_forbidden}

  defp validate_purpose(purpose)
       when purpose in [
              :external_authorization,
              :external_interaction,
              :payment,
              :sensitive_input
            ],
       do: {:ok, purpose}

  defp validate_purpose(_purpose), do: {:error, :invalid_purpose}

  defp validate_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 and ttl_ms <= @max_ttl_ms,
    do: {:ok, ttl_ms}

  defp validate_ttl(_ttl_ms), do: {:error, :invalid_ttl}

  defp normalize_allowed_hosts(hosts) when is_list(hosts) and hosts != [] do
    Enum.reduce_while(hosts, {:ok, MapSet.new()}, fn host, {:ok, normalized} ->
      case normalize_allowed_host(host) do
        {:ok, host} -> {:cont, {:ok, MapSet.put(normalized, host)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_allowed_hosts(_hosts), do: {:error, :missing_allowed_hosts}

  defp normalize_allowed_host(host) when is_binary(host) and host != "" do
    normalized = String.downcase(host)

    if String.contains?(normalized, ["*", "/", "@", "?", "#"]) do
      {:error, :invalid_allowed_host}
    else
      case URI.new("https://" <> normalized) do
        {:ok, %URI{host: ^normalized, path: nil}} -> {:ok, normalized}
        _other -> {:error, :invalid_allowed_host}
      end
    end
  end

  defp normalize_allowed_host(_host), do: {:error, :invalid_allowed_host}

  defp build_url(builder, elicitation_id) when is_function(builder, 1) do
    {:ok, builder.(elicitation_id)}
  rescue
    error -> {:error, {:url_builder_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:url_builder_failed, inspect({kind, reason})}}
  end

  defp build_url(url, _elicitation_id) when is_binary(url), do: {:ok, url}
  defp build_url(_url, _elicitation_id), do: {:error, :invalid_url}

  defp validate_url(url, allowed_hosts)
       when is_binary(url) and byte_size(url) <= @max_url_bytes do
    case URI.new(url) do
      {:ok, uri} -> validate_parsed_url(uri, allowed_hosts)
      {:error, _reason} -> {:error, :invalid_url}
    end
  end

  defp validate_url(_url, _allowed_hosts), do: {:error, :invalid_url}

  defp validate_parsed_url(uri, allowed_hosts) do
    host = uri.host && String.downcase(uri.host)

    cond do
      uri.scheme != "https" -> {:error, :https_required}
      not is_binary(host) or host == "" -> {:error, :invalid_url}
      not MapSet.member?(allowed_hosts, host) -> {:error, :url_host_not_allowed}
      not is_nil(uri.userinfo) -> {:error, :url_userinfo_forbidden}
      not is_nil(uri.fragment) -> {:error, :url_fragment_forbidden}
      not URIPolicy.valid_percent_encoding?(uri.path) -> {:error, :invalid_url}
      not URIPolicy.valid_percent_encoding?(uri.query) -> {:error, :invalid_url}
      sensitive_query?(uri.query) -> {:error, :sensitive_url_data}
      true -> {:ok, URI.to_string(uri)}
    end
  end

  defp sensitive_query?(nil), do: false

  # A query that cannot be decoded counts as sensitive.
  defp sensitive_query?(query) do
    not URIPolicy.valid_percent_encoding?(query) or
      query
      |> URI.query_decoder()
      |> Enum.any?(fn {key, _value} ->
        MapSet.member?(@sensitive_query_keys, String.downcase(key))
      end)
  end

  defp ensure_active(elicitation, now_ms) do
    if expired?(elicitation, now_ms), do: {:error, :expired}, else: :ok
  end

  defp normalize_action(action) when action in [:accept, "accept"], do: {:ok, :accept}
  defp normalize_action(action) when action in [:decline, "decline"], do: {:ok, :decline}
  defp normalize_action(action) when action in [:cancel, "cancel"], do: {:ok, :cancel}
  defp normalize_action(_action), do: {:error, :invalid_action}

  defp ensure_url_content_absent(nil), do: :ok
  defp ensure_url_content_absent(_content), do: {:error, :url_content_forbidden}

  defp ensure_response_transition(%__MODULE__{action: action}, _next) when not is_nil(action),
    do: {:error, :already_responded}

  defp ensure_response_transition(%__MODULE__{completed_at: completed_at}, action)
       when is_integer(completed_at) and action != :accept,
       do: {:error, :already_completed}

  defp ensure_response_transition(%__MODULE__{}, _action), do: :ok

  defp ensure_binding(elicitation, session_id, principal_fingerprint) do
    if secure_equal?(elicitation.session_id, session_id) and
         secure_equal?(elicitation.principal_fingerprint, principal_fingerprint) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp ensure_completable(%__MODULE__{completed_at: completed_at}) when is_integer(completed_at),
    do: {:error, :already_completed}

  defp ensure_completable(%__MODULE__{action: action}) when action in [:decline, :cancel],
    do: {:error, :declined}

  defp ensure_completable(%__MODULE__{}), do: :ok

  defp format_reason({:missing_verified_identity, key}), do: "#{key} is required"
  defp format_reason({:url_builder_failed, reason}), do: "URL builder failed: #{reason}"
  defp format_reason(reason), do: inspect(reason)
end
