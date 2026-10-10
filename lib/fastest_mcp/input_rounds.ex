defmodule FastestMCP.InputRounds do
  @moduledoc false
  # The questions of the handler helpers (`Context.elicit/4`, `Context.sample/3`,
  # `Context.list_roots/2`) in a request of MCP 2026-07-28 that runs without a
  # background task: multi-round-trip requests. Such a request has no way back
  # to its client, so a question that the request doesn't answer ends the
  # handler with an `InputRequiredResult` asking it. The client answers and
  # sends the request again, and the handler runs again from the start.
  #
  # The n-th question of a request has the key "fastestmcp-n" and must be the
  # same request in every round, which a fingerprint checks. The answers to
  # earlier questions travel in the request state, signed with the runtime's
  # secret and bound to the call (method, target, arguments, and caller); the
  # handler's own request state travels inside it. A request state that names
  # another server, such as an upstream behind a proxy, is the handler's own.

  import FastestMCP.Protocol.Version
  import FastestMCP.Util, only: [secure_equal?: 2]

  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TaskOwner

  @methods ["tools/call", "prompts/get", "resources/read"]
  @state_prefix "fastestmcp-rounds:"
  @version 1

  # Runs `fun`, which invokes the handler of `operation` with the context it
  # receives. In a request from a 2026-07-28 client, a question of the helpers
  # that the request doesn't answer ends `fun` with an `InputRequiredResult`.
  def run(%{context: %Context{} = context} = operation, fun) when is_function(fun, 1) do
    if rounds?(operation) do
      key = {__MODULE__, context.request_id}
      rounds = start!(operation)
      Process.put(key, rounds)

      try do
        context |> handler_context(rounds) |> fun.() |> finish(Process.get(key))
      catch
        :throw, {__MODULE__, %InputRequiredResult{} = result} -> result
      after
        Process.delete(key)
      end
    else
      fun.(context)
    end
  end

  # Whether the helpers of `context` ask through rounds: in the handler's
  # process, while `run/2` runs it.
  def active?(%Context{request_id: request_id}),
    do: Process.get({__MODULE__, request_id}) != nil

  # The answer to the next question of the handler, an MCP request map; when
  # the request doesn't answer it, the handler ends with the question.
  def ask!(%Context{request_id: request_id}, %{"method" => _method} = request) do
    key = {__MODULE__, request_id}
    rounds = Process.get(key)
    index = rounds.asked + 1
    fingerprint = fingerprint(request)

    case Enum.at(rounds.answers, index - 1) do
      [^fingerprint, answer] ->
        Process.put(key, %{rounds | asked: index})
        answer

      [_other, _answer] ->
        raise changed_question(index)

      nil ->
        cond do
          rounds.pending == fingerprint and is_map(rounds.latest) ->
            answers = rounds.answers ++ [[fingerprint, rounds.latest]]

            Process.put(key, %{rounds | asked: index, answers: answers, pending: nil, latest: nil})

            rounds.latest

          rounds.pending not in [nil, fingerprint] ->
            raise changed_question(index)

          true ->
            state = encode(rounds, rounds.answers, fingerprint, rounds.user_state)
            result = InputRequiredResult.new(%{key(index) => request}, request_state: state)
            throw({__MODULE__, result})
        end
    end
  end

  # The value of `fun`, computed in the first round that reaches it and
  # replayed in later rounds as the answers are; outside rounds, `fun.()`.
  # The value must have a JSON form.
  def once(%Context{request_id: request_id}, fun) when is_function(fun, 0) do
    key = {__MODULE__, request_id}

    case Process.get(key) do
      nil ->
        fun.()

      rounds ->
        index = rounds.asked + 1

        case Enum.at(rounds.answers, index - 1) do
          ["once", value] ->
            Process.put(key, %{rounds | asked: index})
            value

          nil when is_nil(rounds.pending) ->
            # As it will be replayed: in its JSON form.
            value = fun.() |> JSON.encode!() |> JSON.decode!()

            Process.put(key, %{
              rounds
              | asked: index,
                answers: rounds.answers ++ [["once", value]]
            })

            value

          _question ->
            raise changed_question(index)
        end
    end
  end

  defp rounds?(%{invocation: :protocol, method: method, context: context})
       when method in @methods,
       do:
         is_modern(context.negotiated_protocol_version) and not Context.background_task?(context)

  defp rounds?(_operation), do: false

  defp start!(%{context: context} = operation) do
    rounds = %{
      server_name: context.server_name,
      call: call(operation),
      answers: [],
      pending: nil,
      latest: nil,
      user_state: context.request_state,
      asked: 0
    }

    case decode!(context.request_state, rounds) do
      nil ->
        rounds

      %{"a" => answers, "p" => pending, "u" => user_state} ->
        latest = pending && context.input_responses[key(length(answers) + 1)]

        %{
          rounds
          | answers: answers,
            pending: pending,
            latest: if(is_map(latest), do: Map.delete(latest, "resultType")),
            user_state: user_state
        }
    end
  end

  # The handler sees its own request state, and the answers to its own input
  # requests only.
  defp handler_context(context, %{pending: nil} = rounds),
    do: %{context | request_state: rounds.user_state}

  defp handler_context(context, rounds) do
    %{
      context
      | request_state: rounds.user_state,
        input_responses: Map.delete(context.input_responses, key(length(rounds.answers) + 1))
    }
  end

  # A handler's own `InputRequiredResult` keeps the helpers' answers so far.
  defp finish(%InputRequiredResult{} = result, rounds) do
    answers =
      if rounds.pending && rounds.latest,
        do: rounds.answers ++ [[rounds.pending, rounds.latest]],
        else: rounds.answers

    if answers == [],
      do: result,
      else: %{result | request_state: encode(rounds, answers, nil, result.request_state)}
  end

  defp finish(result, _rounds), do: result

  defp key(index), do: "fastestmcp-#{index}"

  defp encode(rounds, answers, pending, user_state) do
    body =
      JSON.encode!(%{
        "v" => @version,
        "s" => rounds.server_name,
        "b" => digest(rounds.call),
        "a" => answers,
        "p" => pending,
        "u" => user_state
      })

    @state_prefix <>
      Base.url_encode64(body, padding: false) <>
      "." <> Base.url_encode64(mac(rounds.server_name, body), padding: false)
  end

  defp decode!(@state_prefix <> encoded, rounds) do
    with [encoded_body, encoded_mac] <- String.split(encoded, ".", parts: 2),
         {:ok, body} <- Base.url_decode64(encoded_body, padding: false),
         {:ok, mac} <- Base.url_decode64(encoded_mac, padding: false),
         {:ok, %{"v" => @version, "s" => server_name} = fields} <- JSON.decode(body) do
      cond do
        server_name != rounds.server_name -> nil
        not secure_equal?(mac, mac(server_name, body)) -> raise invalid_state(:not_issued)
        fields["b"] != digest(rounds.call) -> raise invalid_state(:another_call)
        true -> fields
      end
    else
      _malformed -> raise invalid_state(:malformed)
    end
  end

  defp decode!(_handler_state, _rounds), do: nil

  defp mac(server_name, body) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} -> :crypto.mac(:hmac, :sha256, runtime.signing_secret.value, body)
      {:error, :not_found} -> raise Error.not_found(:server, server_name)
    end
  end

  # The call a request state belongs to, and its digest.
  defp call(%{method: method, target: target, arguments: arguments, context: context}),
    do: {method, target, arguments, TaskOwner.from_context(context)}

  defp digest(call) do
    call
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp fingerprint(request) do
    request
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp changed_question(index) do
    %Error{
      code: :internal_error,
      message:
        "the handler asked a different question #{index} than in an earlier round: " <>
          "a handler must ask the same questions in the same order in every round"
    }
  end

  defp invalid_state(reason) do
    detail =
      case reason do
        :another_call -> ": it belongs to another call"
        :not_issued -> ": this server did not issue it, or it issued it before a restart"
        :malformed -> ""
      end

    %Error{code: :invalid_params, message: "invalid request state" <> detail}
  end
end
