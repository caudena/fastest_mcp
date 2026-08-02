defmodule FastestMCP.HTTP do
  @moduledoc """
  Small HTTP helper used by runtime code that does not need the stricter auth SSRF protections.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  @default_timeout 5_000
  @default_headers [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"FastestMCP/0.2"}]

  @doc "Fetches and decodes a JSON response."
  def get_json(url, opts \\ []) when is_binary(url) do
    case request(:get, url, opts) do
      {:ok, status, _headers, body} when status == 200 ->
        JSON.decode(body)

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
        with {:ok, decoded} <- JSON.decode(body) do
          {:ok, status, headers, decoded}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds an elicitation request."
  def request(method, url, opts \\ [])
      when method in [:get, :post, :put, :patch, :delete] and is_binary(url) and is_list(opts) do
    case Keyword.get(opts, :requester) do
      requester when is_function(requester, 3) ->
        requester.(method, url, Keyword.delete(opts, :requester))

      nil ->
        with {:ok, request_ref} <- async_request(method, url, opts) do
          notify_request_started(opts, request_ref)

          try do
            await_response(request_ref, Keyword.get(opts, :timeout_ms, @default_timeout))
          after
            _ = cancel_request(request_ref)
            flush_response_messages(request_ref)
          end
        end
    end
  end

  @doc false
  def stream_request(method, url, opts \\ [])
      when method in [:get, :post, :put, :patch, :delete] and is_binary(url) and is_list(opts) do
    request_opts =
      opts
      |> Keyword.put_new(:request_timeout_ms, :infinity)
      |> Keyword.put(:stream_response, true)

    with {:ok, request_ref} <- async_request(method, url, request_opts) do
      notify_request_started(opts, request_ref)
      {:ok, request_ref}
    end
  end

  @doc false
  def cancel_request(nil), do: :ok

  def cancel_request(request_ref) do
    :httpc.cancel_request(request_ref)
  catch
    :exit, _reason -> :ok
  end

  defp async_request(method, url, opts) do
    with :ok <- ensure_http_apps() do
      request_config = build_request_config(method, url, opts)
      start_request_relay(request_config)
    end
  end

  defp build_request_config(method, url, opts) do
    request_url =
      url
      |> append_query(Keyword.get(opts, :query))
      |> then(fn default_url -> Keyword.get(opts, :request_url, default_url) end)

    headers =
      @default_headers
      |> Kernel.++(normalize_headers(Keyword.get(opts, :headers, [])))
      |> maybe_add_content_type(opts)

    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    uri = URI.parse(request_url)

    http_options =
      [
        timeout: Keyword.get(opts, :request_timeout_ms, timeout),
        connect_timeout: timeout
      ]
      |> Keyword.merge(Keyword.get(opts, :http_options, []))
      |> maybe_put_ssl_options(uri)
      |> maybe_put_server_name_indication(opts)

    request = request_tuple(method, request_url, headers, opts)
    request_opts = async_request_options(opts)

    {method, request, http_options, request_opts, Keyword.get(opts, :profile)}
  end

  defp async_request_options(opts) do
    [sync: false]
    |> maybe_stream_response(Keyword.get(opts, :stream_response, false))
  end

  defp maybe_stream_response(request_opts, true),
    do: Keyword.put(request_opts, :stream, :self)

  defp maybe_stream_response(request_opts, false), do: request_opts

  defp start_request_relay(request_config) do
    caller = self()
    start_ref = make_ref()

    {relay_pid, monitor_ref} =
      spawn_monitor(fn -> request_relay(caller, start_ref, request_config) end)

    receive do
      {^start_ref, {:ok, request_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, request_ref}

      {^start_ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^relay_pid, reason} ->
        {:error, {:request_relay_down, reason}}
    end
  end

  defp request_relay(caller, start_ref, {method, request, http_options, request_opts, profile}) do
    caller_ref = Process.monitor(caller)
    request_opts = Keyword.put(request_opts, :receiver, self())

    case start_httpc_request(method, request, http_options, request_opts, profile) do
      {:ok, request_ref} ->
        send(caller, {start_ref, {:ok, request_ref}})
        relay_responses(caller, caller_ref, request_ref)

      {:error, reason} ->
        Process.demonitor(caller_ref, [:flush])
        send(caller, {start_ref, {:error, reason}})
    end
  end

  defp start_httpc_request(method, request, http_options, request_opts, nil) do
    :httpc.request(method, request, http_options, request_opts)
  end

  defp start_httpc_request(method, request, http_options, request_opts, profile) do
    :httpc.request(method, request, http_options, request_opts, profile)
  end

  defp relay_responses(caller, caller_ref, request_ref) do
    receive do
      {:http, {^request_ref, _response} = message} ->
        send(caller, {:http, message})

      {:http, {^request_ref, _stream_kind, _data} = message} ->
        send(caller, {:http, message})

        unless terminal_response?(message) do
          relay_responses(caller, caller_ref, request_ref)
        end

      {:http, {^request_ref, _stream_kind, _headers, _handler_pid} = message} ->
        send(caller, {:http, message})
        relay_responses(caller, caller_ref, request_ref)

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        _ = cancel_request(request_ref)
    end
  end

  defp terminal_response?({_request_ref, :stream_start, _headers}), do: false
  defp terminal_response?({_request_ref, :stream, _chunk}), do: false
  defp terminal_response?({_request_ref, :stream_end, _headers}), do: true

  defp await_response(request_ref, :infinity) do
    receive do
      {:http, {^request_ref, {{_version, status, _reason}, headers, body}}} ->
        {:ok, status, normalize_response_headers(headers), body}

      {:http, {^request_ref, {:error, reason}}} ->
        {:error, reason}
    end
  end

  defp await_response(request_ref, timeout) do
    receive do
      {:http, {^request_ref, {{_version, status, _reason}, headers, body}}} ->
        {:ok, status, normalize_response_headers(headers), body}

      {:http, {^request_ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp notify_request_started(opts, request_ref) do
    case Keyword.get(opts, :request_started) do
      callback when is_function(callback, 1) -> callback.(request_ref)
      nil -> :ok
    end
  end

  defp flush_response_messages(request_ref) do
    receive do
      {:http, {^request_ref, _message}} ->
        flush_response_messages(request_ref)

      {:http, {^request_ref, _stream_kind, _message}} ->
        flush_response_messages(request_ref)

      {:http, {^request_ref, _stream_kind, _headers, _pid}} ->
        flush_response_messages(request_ref)
    after
      0 -> :ok
    end
  end

  defp ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok = :httpc.set_options(max_sessions: 100)
      :ok
    end
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp normalize_response_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {to_string(key), to_string(value)}
    end)
  end

  defp request_tuple(:get, url, headers, _opts) do
    {String.to_charlist(url), headers}
  end

  defp request_tuple(:delete, url, headers, _opts) do
    {String.to_charlist(url), headers}
  end

  defp request_tuple(method, url, headers, opts) when method in [:post, :put, :patch] do
    {content_type, body} = request_body(opts)
    {String.to_charlist(url), headers, content_type, body}
  end

  defp request_body(opts) do
    cond do
      Keyword.has_key?(opts, :json) ->
        {request_content_type(opts, "application/json"), JSON.encode!(Keyword.get(opts, :json))}

      Keyword.has_key?(opts, :form) ->
        body =
          opts
          |> Keyword.get(:form, %{})
          |> normalize_form()
          |> URI.encode_query()

        {request_content_type(opts, "application/x-www-form-urlencoded"), body}

      Keyword.has_key?(opts, :multipart) ->
        {content_type, body} = multipart_body(Keyword.get(opts, :multipart, %{}))
        {to_charlist(content_type), body}

      Keyword.has_key?(opts, :body) ->
        {request_content_type(opts, "application/octet-stream"), Keyword.get(opts, :body)}

      true ->
        {~c"application/json", ""}
    end
  end

  defp request_content_type(opts, default) do
    opts
    |> Keyword.get(:content_type)
    |> then(&(&1 || default))
    |> to_string()
    |> to_charlist()
  end

  defp normalize_form(form) when is_map(form), do: form
  defp normalize_form(form) when is_list(form), do: Enum.into(form, %{})

  defp multipart_body(parts) do
    boundary =
      18
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    body =
      parts
      |> normalize_multipart_parts()
      |> Enum.map_join("", &multipart_part(&1, boundary))
      |> Kernel.<>("--#{boundary}--\r\n")

    {"multipart/form-data; boundary=#{boundary}", body}
  end

  defp normalize_multipart_parts(parts) when is_map(parts), do: Map.to_list(parts)
  defp normalize_multipart_parts(parts) when is_list(parts), do: parts

  defp multipart_part({name, value}, boundary) do
    {headers, content} = multipart_part_content(name, value)

    [
      "--",
      boundary,
      "\r\n",
      Enum.map_join(headers, "", fn {key, header_value} -> "#{key}: #{header_value}\r\n" end),
      "\r\n",
      content,
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp multipart_part_content(name, %{filename: filename, content: content} = part) do
    content_type = Map.get(part, :content_type, Map.get(part, "content_type"))
    multipart_file_content(name, filename, content, content_type)
  end

  defp multipart_part_content(name, %{"filename" => filename, "content" => content} = part) do
    content_type = Map.get(part, "content_type", Map.get(part, :content_type))
    multipart_file_content(name, filename, content, content_type)
  end

  defp multipart_part_content(name, {filename, content}) do
    multipart_file_content(name, filename, content, nil)
  end

  defp multipart_part_content(name, {filename, content, content_type}) do
    multipart_file_content(name, filename, content, content_type)
  end

  defp multipart_part_content(name, content) do
    {[content_disposition(name)], scalar_to_multipart(content)}
  end

  defp multipart_file_content(name, filename, content, content_type) do
    headers =
      [content_disposition(name, filename)]
      |> maybe_multipart_content_type(content_type)

    {headers, scalar_to_multipart(content)}
  end

  defp content_disposition(name) do
    {"content-disposition", ~s(form-data; name="#{escape_multipart_param(name)}")}
  end

  defp content_disposition(name, filename) do
    {"content-disposition",
     ~s(form-data; name="#{escape_multipart_param(name)}"; filename="#{escape_multipart_param(filename)}")}
  end

  defp maybe_multipart_content_type(headers, nil), do: headers
  defp maybe_multipart_content_type(headers, ""), do: headers

  defp maybe_multipart_content_type(headers, content_type) do
    headers ++ [{"content-type", to_string(content_type)}]
  end

  defp scalar_to_multipart(value) when is_binary(value), do: value
  defp scalar_to_multipart(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar_to_multipart(value) when is_boolean(value), do: to_string(value)
  defp scalar_to_multipart(nil), do: ""
  defp scalar_to_multipart(value), do: JSON.encode!(value)

  defp escape_multipart_param(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp maybe_put_ssl_options(options, %URI{scheme: "https"}) do
    ssl_opts =
      cond do
        :erlang.function_exported(:httpc, :ssl_verify_host_options, 1) ->
          :httpc.ssl_verify_host_options(true)

        :erlang.function_exported(:public_key, :cacerts_get, 0) ->
          [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

        true ->
          [verify: :verify_none]
      end

    Keyword.put(options, :ssl, ssl_opts)
  end

  defp maybe_put_ssl_options(options, _uri), do: options

  defp maybe_put_server_name_indication(options, opts) do
    case Keyword.get(opts, :ssl_server_name) do
      nil ->
        options

      server_name ->
        Keyword.update(
          options,
          :ssl,
          [server_name_indication: to_charlist(server_name)],
          fn ssl_opts ->
            Keyword.put(ssl_opts, :server_name_indication, to_charlist(server_name))
          end
        )
    end
  end

  defp append_query(url, nil), do: url
  defp append_query(url, []), do: url

  defp append_query(url, query) do
    uri = URI.parse(url)
    encoded = URI.encode_query(normalize_query(query))
    separator = if is_binary(uri.query) and uri.query != "", do: "&", else: "?"
    url <> separator <> encoded
  end

  defp normalize_query(query) when is_map(query), do: Map.to_list(query)
  defp normalize_query(query) when is_list(query), do: query

  defp maybe_add_content_type(headers, opts) do
    cond do
      Keyword.has_key?(opts, :multipart) ->
        headers

      Keyword.has_key?(opts, :content_type) ->
        put_content_type(headers, request_content_type(opts, "application/octet-stream"))

      Keyword.has_key?(opts, :json) ->
        put_content_type(headers, request_content_type(opts, "application/json"))

      Keyword.has_key?(opts, :form) ->
        put_content_type(headers, request_content_type(opts, "application/x-www-form-urlencoded"))

      true ->
        headers
    end
  end

  defp put_content_type(headers, content_type) do
    if Enum.any?(headers, fn {key, _value} -> key == ~c"content-type" end) do
      headers
    else
      headers ++ [{~c"content-type", content_type}]
    end
  end
end
