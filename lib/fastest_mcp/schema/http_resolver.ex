defmodule FastestMCP.Schema.HTTPResolver do
  @moduledoc """
  Opt-in HTTPS resolver for remote JSON Schema resources.

  Resolution is intentionally disabled by default. To enable it, pass
  `http_resolver:` to `FastestMCP.Schema.compile/2` with an explicit
  `:allowed_hosts` list. Only HTTPS on an allowed port is accepted; redirects,
  non-JSON responses, and oversized bodies fail closed.
  """

  @behaviour JSV.Resolver

  alias FastestMCP.HTTP
  alias FastestMCP.MIME
  alias FastestMCP.Schema.Resolver

  @default_timeout_ms 5_000
  @default_max_body_bytes 1_048_576

  @impl true
  def resolve(url, opts) when is_binary(url) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_url(url, opts),
         {:ok, status, headers, body} <- request(url, opts),
         :ok <- validate_status(status),
         :ok <- validate_content_type(headers),
         {:ok, body} <- normalize_body(body, opts),
         {:ok, schema} <- JSON.decode(body),
         {:ok, normalized} <- Resolver.normalize_remote_schema(url, schema, opts) do
      {:normal, normalized}
    end
  rescue
    error -> {:error, {:resolver_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:resolver_failure, kind}}
  end

  def resolve(url, _opts), do: {:error, {:invalid_remote_schema_uri, url}}

  defp validate_options(opts) do
    with allowed_hosts when is_list(allowed_hosts) and allowed_hosts != [] <-
           Keyword.get(opts, :allowed_hosts),
         true <- Enum.all?(allowed_hosts, &(is_binary(&1) and String.trim(&1) != "")),
         timeout when is_integer(timeout) and timeout > 0 <-
           Keyword.get(opts, :timeout_ms, @default_timeout_ms),
         max_body when is_integer(max_body) and max_body > 0 <-
           Keyword.get(opts, :max_body_bytes, @default_max_body_bytes),
         ports when is_list(ports) and ports != [] <- Keyword.get(opts, :allowed_ports, [443]),
         true <- Enum.all?(ports, &(is_integer(&1) and &1 in 1..65_535)),
         requester <- Keyword.get(opts, :requester),
         true <- is_nil(requester) or is_function(requester, 3) do
      :ok
    else
      _other -> {:error, :invalid_http_resolver_options}
    end
  end

  defp validate_url(url, opts) do
    allowed_hosts =
      opts
      |> Keyword.fetch!(:allowed_hosts)
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.downcase()))

    allowed_ports = Keyword.get(opts, :allowed_ports, [443])

    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        userinfo: nil,
        fragment: nil
      }
      when is_binary(host) ->
        port = port || 443

        if String.downcase(host) in allowed_hosts and port in allowed_ports do
          :ok
        else
          {:error, {:restricted_url, url}}
        end

      _other ->
        {:error, {:restricted_url, url}}
    end
  end

  defp request(url, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    request_opts = [
      timeout_ms: timeout_ms,
      request_timeout_ms: timeout_ms,
      http_options: [autoredirect: false]
    ]

    request_opts =
      case Keyword.get(opts, :requester) do
        requester when is_function(requester, 3) ->
          Keyword.put(request_opts, :requester, requester)

        _other ->
          request_opts
      end

    case Keyword.get(opts, :requester) do
      requester when is_function(requester, 3) ->
        HTTP.request(:get, url, request_opts)

      _other ->
        HTTP.bounded_request(:get, url, max_body_bytes, request_opts)
    end
  end

  defp validate_status(200), do: :ok
  defp validate_status(status) when status in 300..399, do: {:error, {:redirect_refused, status}}
  defp validate_status(status), do: {:error, {:http_status, status}}

  defp validate_content_type(headers) do
    content_type =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == "content-type", do: to_string(value)
      end)

    cond do
      is_nil(content_type) ->
        {:error, :missing_content_type}

      MIME.json?(content_type) ->
        :ok

      true ->
        {:error, {:unsupported_content_type, content_type}}
    end
  end

  defp normalize_body(body, opts) do
    body = IO.iodata_to_binary(body)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    if byte_size(body) <= max_body_bytes do
      {:ok, body}
    else
      {:error, {:body_too_large, byte_size(body), max_body_bytes}}
    end
  end
end
