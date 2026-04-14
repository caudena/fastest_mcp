defmodule FastestMCP.Auth.SSRF do
  @moduledoc """
  SSRF-safe HTTP helper used by auth code when fetching remote documents.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  import Bitwise

  alias FastestMCP.HTTP

  @default_timeout_ms 5_000
  @default_overall_timeout_ms 30_000
  @default_max_size_bytes 5_120

  defmodule ValidatedURL do
    @moduledoc """
    URL that has passed SSRF validation and hostname resolution checks.
    """

    defstruct [:original_url, :hostname, :port, :scheme, :path_query, :resolved_ips]
  end

  @doc "Fetches and decodes a JSON response."
  def get_json(url, opts \\ []) when is_binary(url) do
    case request(:get, url, opts) do
      {:ok, 200, _headers, body} ->
        Jason.decode(body)

      {:ok, status, _headers, body} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Posts form data and decodes the JSON response."
  def post_form_json(url, form, opts \\ []) when is_binary(url) do
    case request(:post, url, Keyword.put(opts, :form, form)) do
      {:ok, status, headers, body} ->
        with {:ok, decoded} <- Jason.decode(body) do
          {:ok, status, headers, decoded}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Performs an SSRF-safe HTTP request after validating and resolving the URL."
  def request(method, url, opts \\ [])
      when method in [:get, :post] and is_binary(url) and is_list(opts) do
    with {:ok, validated} <- validate_url(url, opts) do
      do_request(method, validated, opts)
    end
  end

  @doc "Validates a URL against the SSRF rules enforced by this module."
  def validate_url(url, opts \\ []) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" ->
        {:error, "URL must use HTTPS"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "URL must have a host"}

      Keyword.get(opts, :require_path, false) and uri.path in [nil, "", "/"] ->
        {:error, "URL must have a non-root path"}

      true ->
        port = uri.port || default_port(uri.scheme)

        with {:ok, resolved_ips} <- resolve_hostname(uri.host, port, opts),
             [] <- Enum.reject(resolved_ips, &allowed_ip?/1) do
          {:ok,
           %ValidatedURL{
             original_url: url,
             hostname: uri.host,
             port: port,
             scheme: uri.scheme,
             path_query: path_query(uri),
             resolved_ips: resolved_ips
           }}
        else
          blocked_ips when is_list(blocked_ips) ->
            {:error, "URL resolves to blocked IP address(es): #{Enum.join(blocked_ips, ", ")}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Formats a resolved IP address for URL comparison and diagnostics."
  def format_ip_for_url(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, {_a, _b, _c, _d}} -> ip
      {:ok, {_a, _b, _c, _d, _e, _f, _g, _h}} -> "[" <> ip <> "]"
      :error -> ip
    end
  end

  @doc "Returns whether the given IP address is allowed."
  def allowed_ip?(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, parsed} -> allowed_ip?(parsed)
      :error -> false
    end
  end

  def allowed_ip?({a, b, _c, _d}) do
    cond do
      a in [0, 10, 127, 255] -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 100 and b in 64..127 -> false
      a >= 224 -> false
      true -> true
    end
  end

  def allowed_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def allowed_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  def allowed_ip?({0, 0, 0, 0, 0, 65_535, seg7, seg8}) do
    allowed_ip?(embedded_ipv4(seg7, seg8))
  end

  def allowed_ip?({seg1, _seg2, _seg3, _seg4, _seg5, _seg6, _seg7, _seg8}) do
    cond do
      (seg1 &&& 0xFF00) == 0xFF00 -> false
      (seg1 &&& 0xFFC0) == 0xFE80 -> false
      (seg1 &&& 0xFE00) == 0xFC00 -> false
      true -> true
    end
  end

  defp do_request(method, %ValidatedURL{} = validated, opts) do
    requester = Keyword.get(opts, :requester, &default_requester/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    overall_timeout_ms = Keyword.get(opts, :overall_timeout_ms, @default_overall_timeout_ms)
    max_size_bytes = Keyword.get(opts, :max_size_bytes, @default_max_size_bytes)
    started_at = System.monotonic_time(:millisecond)

    validated.resolved_ips
    |> Enum.reduce_while({:error, "no resolved IPs succeeded"}, fn ip, _acc ->
      remaining_ms = overall_timeout_ms - (System.monotonic_time(:millisecond) - started_at)

      if remaining_ms <= 0 do
        {:halt, {:error, "overall timeout exceeded"}}
      else
        request_opts = [
          headers: pinned_headers(validated, opts),
          timeout_ms: min(timeout_ms, remaining_ms),
          http_options: [autoredirect: false],
          ssl_server_name: validated.hostname,
          form: Keyword.get(opts, :form)
        ]

        case requester.(method, pinned_url(validated, ip), request_opts) do
          {:ok, status, headers, body} ->
            case validate_body_size(headers, body, max_size_bytes) do
              :ok -> {:halt, {:ok, status, headers, body}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, _reason} = error ->
            {:cont, error}
        end
      end
    end)
  end

  defp validate_body_size(headers, body, max_size_bytes) do
    headers_map =
      headers
      |> Enum.into(%{}, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)

    with :ok <- validate_content_length(headers_map["content-length"], max_size_bytes),
         true <- byte_size(body) <= max_size_bytes do
      :ok
    else
      false ->
        {:error, "response too large: exceeded #{max_size_bytes} bytes"}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_content_length(nil, _max_size_bytes), do: :ok

  defp validate_content_length(content_length, max_size_bytes) do
    case Integer.parse(content_length) do
      {size, ""} when size > max_size_bytes ->
        {:error, "response too large: #{size} bytes"}

      _ ->
        :ok
    end
  end

  defp pinned_headers(validated, opts) do
    host_header = host_header(validated.hostname, validated.port, validated.scheme)

    custom_headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "host" end)

    [{"host", host_header} | custom_headers]
  end

  defp host_header(hostname, port, "https") when port == 443, do: hostname
  defp host_header(hostname, port, "http") when port == 80, do: hostname
  defp host_header(hostname, port, _scheme), do: "#{hostname}:#{port}"

  defp pinned_url(validated, ip) do
    "#{validated.scheme}://#{format_ip_for_url(ip)}:#{validated.port}#{validated.path_query}"
  end

  defp path_query(%URI{} = uri) do
    (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
  end

  defp resolve_hostname(hostname, port, opts) do
    case Keyword.get(opts, :resolver) do
      nil ->
        default_resolver(hostname, port)

      resolver when is_function(resolver, 2) ->
        resolver.(hostname, port)

      resolver when is_function(resolver, 1) ->
        resolver.(hostname)
    end
  end

  defp default_resolver(hostname, port) do
    case parse_ip(hostname) do
      {:ok, _ip} ->
        {:ok, [hostname]}

      :error ->
        ipv4 = lookup_family(hostname, port, :inet)
        ipv6 = lookup_family(hostname, port, :inet6)

        ips =
          (ipv4 ++ ipv6)
          |> Enum.uniq()

        if ips == [] do
          {:error, "DNS resolution returned no addresses for #{hostname}"}
        else
          {:ok, ips}
        end
    end
  end

  defp lookup_family(hostname, _port, family) do
    case :inet.getaddrs(String.to_charlist(hostname), family) do
      {:ok, addrs} ->
        addrs
        |> Enum.map(fn addr -> addr |> :inet.ntoa() |> to_string() end)

      {:error, _reason} ->
        case :inet.getaddr(String.to_charlist(hostname), family) do
          {:ok, addr} -> [addr |> :inet.ntoa() |> to_string()]
          {:error, _other} -> []
        end
    end
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp embedded_ipv4(seg7, seg8) do
    {
      seg7 >>> 8,
      seg7 &&& 0xFF,
      seg8 >>> 8,
      seg8 &&& 0xFF
    }
  end

  defp default_requester(method, url, request_opts) do
    HTTP.request(method, url, request_opts)
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
end
