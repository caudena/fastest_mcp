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
    if Keyword.get(opts, :live_stream, false) do
      live_stream_request(method, url, opts)
    else
      request_opts =
        opts
        |> Keyword.put_new(:request_timeout_ms, :infinity)
        |> Keyword.put(:stream_response, true)

      with {:ok, request_ref} <- async_request(method, url, request_opts) do
        notify_request_started(opts, request_ref)
        {:ok, request_ref}
      end
    end
  end

  @doc false
  def bounded_request(method, url, max_body_bytes, opts \\ [])
      when method in [:get, :post, :put, :patch, :delete] and is_binary(url) and
             is_integer(max_body_bytes) and max_body_bytes > 0 and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)

    with {:ok, request_ref} <-
           stream_request(
             method,
             url,
             Keyword.put_new(opts, :request_timeout_ms, timeout_ms)
           ) do
      try do
        receive_bounded_response(request_ref, max_body_bytes, timeout_ms, nil, [], 0)
      after
        _ = cancel_request(request_ref)
        flush_response_messages(request_ref)
      end
    end
  end

  @doc false
  def cancel_request(nil), do: :ok

  def cancel_request({:fastest_mcp_mint_stream, relay_pid, request_ref})
      when is_pid(relay_pid) and is_reference(request_ref) do
    send(relay_pid, {:cancel_stream, request_ref})
    :ok
  end

  def cancel_request(request_ref) do
    :httpc.cancel_request(request_ref)
  catch
    :exit, _reason -> :ok
  end

  defp live_stream_request(method, url, opts)
       when method in [:get, :post, :put, :patch, :delete] do
    caller = self()
    start_ref = make_ref()
    local_ref = make_ref()

    {relay_pid, monitor_ref} =
      spawn_monitor(fn -> mint_stream_relay(caller, start_ref, local_ref, method, url, opts) end)

    request_ref = {:fastest_mcp_mint_stream, relay_pid, local_ref}

    receive do
      {^start_ref, :ok} ->
        Process.demonitor(monitor_ref, [:flush])
        notify_request_started(opts, request_ref)
        {:ok, request_ref}

      {^start_ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^relay_pid, reason} ->
        {:error, {:stream_relay_down, reason}}
    end
  end

  defp mint_stream_relay(caller, start_ref, local_ref, method, url, opts) do
    caller_ref = Process.monitor(caller)
    request_ref = {:fastest_mcp_mint_stream, self(), local_ref}

    case open_mint_stream(method, url, opts) do
      {:ok, conn, mint_request_ref} ->
        send(caller, {start_ref, :ok})

        state = %{
          status: nil,
          headers: [],
          body: [],
          started?: false,
          done?: false
        }

        try do
          mint_stream_loop(
            caller,
            caller_ref,
            request_ref,
            local_ref,
            conn,
            mint_request_ref,
            state
          )
        after
          _ = Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        Process.demonitor(caller_ref, [:flush])
        send(caller, {start_ref, {:error, reason}})
    end
  end

  defp open_mint_stream(method, url, opts) do
    request_url = append_query(url, Keyword.get(opts, :query))
    uri = URI.parse(request_url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = mint_request_path(uri)

    {headers, body} =
      @default_headers
      |> Kernel.++(normalize_headers(Keyword.get(opts, :headers, [])))
      |> mint_request_payload(method, opts)

    headers = Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

    connect_opts =
      [
        protocols: [:http1],
        transport_opts: mint_transport_opts(uri, opts)
      ]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port, connect_opts),
         {:ok, conn, request_ref} <-
           Mint.HTTP.request(
             conn,
             method |> Atom.to_string() |> String.upcase(),
             path,
             headers,
             body
           ) do
      {:ok, conn, request_ref}
    end
  end

  defp mint_request_payload(headers, method, opts) when method in [:post, :put, :patch] do
    {content_type, body} = request_body(opts)
    {put_content_type(headers, content_type), body}
  end

  defp mint_request_payload(headers, _method, _opts), do: {headers, nil}

  defp mint_request_path(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
  end

  defp mint_transport_opts(%URI{scheme: "https", host: host}, opts) do
    [
      server_name_indication: to_charlist(Keyword.get(opts, :ssl_server_name, host)),
      timeout: Keyword.get(opts, :timeout_ms, @default_timeout)
    ]
  end

  defp mint_transport_opts(_uri, opts),
    do: [timeout: Keyword.get(opts, :timeout_ms, @default_timeout)]

  defp mint_stream_loop(
         caller,
         caller_ref,
         request_ref,
         local_ref,
         conn,
         mint_request_ref,
         state
       ) do
    receive do
      {:cancel_stream, ^local_ref} ->
        :ok

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        :ok

      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            mint_stream_loop(
              caller,
              caller_ref,
              request_ref,
              local_ref,
              conn,
              mint_request_ref,
              state
            )

          {:ok, conn, responses} ->
            state =
              deliver_mint_responses(
                caller,
                request_ref,
                mint_request_ref,
                responses,
                state
              )

            unless state.done? do
              mint_stream_loop(
                caller,
                caller_ref,
                request_ref,
                local_ref,
                conn,
                mint_request_ref,
                state
              )
            end

          {:error, conn, reason, responses} ->
            state =
              deliver_mint_responses(
                caller,
                request_ref,
                mint_request_ref,
                responses,
                state
              )

            unless state.done?, do: send(caller, {:http, {request_ref, {:error, reason}}})
            _ = Mint.HTTP.close(conn)
        end
    end
  end

  defp deliver_mint_responses(caller, request_ref, mint_request_ref, responses, state) do
    Enum.reduce(responses, state, fn
      {:status, ^mint_request_ref, status}, state ->
        %{state | status: status}

      {:headers, ^mint_request_ref, headers}, state ->
        state = %{state | headers: normalize_response_headers(headers)}

        if state.status in 200..299 do
          send(caller, {:http, {request_ref, :stream_start, state.headers}})
          %{state | started?: true}
        else
          state
        end

      {:data, ^mint_request_ref, data}, %{started?: true} = state ->
        send(caller, {:http, {request_ref, :stream, data}})
        state

      {:data, ^mint_request_ref, data}, state ->
        %{state | body: [data | state.body]}

      {:done, ^mint_request_ref}, %{started?: true} = state ->
        send(caller, {:http, {request_ref, :stream_end, state.headers}})
        %{state | done?: true}

      {:done, ^mint_request_ref}, state ->
        body = state.body |> Enum.reverse() |> IO.iodata_to_binary()

        send(
          caller,
          {:http, {request_ref, {{~c"HTTP/1.1", state.status || 0, ~c""}, state.headers, body}}}
        )

        %{state | done?: true}

      _other, state ->
        state
    end)
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
        relay_responses(caller, caller_ref, request_ref, nil)

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

  defp relay_responses(caller, caller_ref, request_ref, stream_handler) do
    receive do
      {:http, {^request_ref, _response} = message} ->
        send(caller, {:http, message})

      {:http, {^request_ref, _stream_kind, _data} = message} ->
        send(caller, {:http, message})

        unless terminal_response?(message) do
          request_next_stream_chunk(stream_handler)
          relay_responses(caller, caller_ref, request_ref, stream_handler)
        end

      {:http, {^request_ref, :stream_start, headers, handler_pid}} ->
        send(caller, {:http, {request_ref, :stream_start, headers}})
        request_next_stream_chunk(handler_pid)
        relay_responses(caller, caller_ref, request_ref, handler_pid)

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        _ = cancel_request(request_ref)
    end
  end

  defp request_next_stream_chunk(handler_pid) when is_pid(handler_pid),
    do: :httpc.stream_next(handler_pid)

  defp request_next_stream_chunk(_handler_pid), do: :ok

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

  defp receive_bounded_response(
         request_ref,
         max_body_bytes,
         timeout_ms,
         headers,
         chunks,
         bytes
       ) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        receive_bounded_response(
          request_ref,
          max_body_bytes,
          timeout_ms,
          normalize_response_headers(response_headers),
          chunks,
          bytes
        )

      {:http, {^request_ref, :stream, chunk}} ->
        chunk = IO.iodata_to_binary(chunk)
        next_bytes = bytes + byte_size(chunk)

        if next_bytes > max_body_bytes do
          {:error, {:body_too_large, next_bytes, max_body_bytes}}
        else
          receive_bounded_response(
            request_ref,
            max_body_bytes,
            timeout_ms,
            headers,
            [chunk | chunks],
            next_bytes
          )
        end

      {:http, {^request_ref, :stream_end, response_headers}} ->
        response_headers =
          if headers in [nil, []], do: normalize_response_headers(response_headers), else: headers

        {:ok, 200, response_headers, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:http, {^request_ref, {{_version, status, _reason}, response_headers, body}}} ->
        body = IO.iodata_to_binary(body)

        if byte_size(body) <= max_body_bytes do
          {:ok, status, normalize_response_headers(response_headers), body}
        else
          {:error, {:body_too_large, byte_size(body), max_body_bytes}}
        end

      {:http, {^request_ref, {:error, reason}}} ->
        {:error, reason}
    after
      timeout_ms -> {:error, :timeout}
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
    Keyword.put(options, :ssl, :httpc.ssl_verify_host_options(true))
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
