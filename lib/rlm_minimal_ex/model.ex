defmodule RlmMinimalEx.Model do
  @moduledoc """
  Thin OpenAI chat completions client for the minimal runtime.
  """

  alias RlmMinimalEx.Trajectory.ModelCall

  @chat_url "https://api.openai.com/v1/chat/completions"

  @type message :: %{String.t() => String.t()}
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @type response ::
          {:ok, :text, String.t(), ModelCall.t()}
          | {:ok, :tool_calls, [tool_call()], ModelCall.t()}
          | {:error, term()}

  @doc """
  Calls the configured chat completions endpoint and normalizes the response.
  """
  @spec chat(String.t(), [message()], keyword()) :: response()
  def chat(model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    case resolve_api_key(opts) do
      {:ok, api_key} -> do_chat(model, messages, tools, api_key, opts)
      {:error, _} = err -> err
    end
  end

  defp do_chat(model, messages, tools, api_key, opts) do
    body =
      %{"model" => model, "messages" => messages}
      |> maybe_add_tools(tools)

    start = System.monotonic_time(:millisecond)
    request_fun = Keyword.get(opts, :request_fn, &Req.post/2)

    request_opts = [
      json: body,
      headers: [{"authorization", "Bearer #{api_key}"}],
      receive_timeout: Keyword.get(opts, :timeout, 120_000)
    ]

    case request_fun.(@chat_url, request_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        duration = System.monotonic_time(:millisecond) - start
        parse_response(resp_body, model, messages, tools, duration)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp parse_response(body, model, messages, tools, duration) do
    usage = body["usage"] || %{}

    model_call = %ModelCall{
      model: model,
      messages_in: length(messages),
      tools_offered: Enum.map(tools, &get_in(&1, ["function", "name"])),
      tool_calls_made: [],
      response_type: nil,
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      duration_ms: duration
    }

    with {:ok, choice} <- extract_choice(body),
         {:ok, message} <- extract_message(choice) do
      parse_message_response(message, model_call)
    end
  end

  defp extract_choice(%{"choices" => [choice | _]}) when is_map(choice), do: {:ok, choice}
  defp extract_choice(body), do: {:error, {:malformed_response, "no choices", body}}

  defp extract_message(%{"message" => msg}) when is_map(msg), do: {:ok, msg}
  defp extract_message(choice), do: {:error, {:malformed_response, "no message", choice}}

  defp parse_message_response(%{"tool_calls" => nil} = message, model_call) do
    {:ok, :text, message["content"] || "",
     %{model_call | response_type: :text, tool_calls_made: []}}
  end

  defp parse_message_response(%{"tool_calls" => tool_calls}, model_call)
       when is_list(tool_calls) do
    with {:ok, parsed} <- parse_tool_calls(tool_calls) do
      names = Enum.map(parsed, & &1.name)

      {:ok, :tool_calls, parsed,
       %{model_call | response_type: :tool_calls, tool_calls_made: names}}
    end
  end

  defp parse_message_response(%{"tool_calls" => _other}, _model_call) do
    {:error, {:malformed_response, "unexpected tool_calls shape"}}
  end

  defp parse_message_response(message, model_call) do
    {:ok, :text, message["content"] || "",
     %{model_call | response_type: :text, tool_calls_made: []}}
  end

  defp parse_tool_calls(tool_calls) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tc, {:ok, acc} ->
      case parse_one_tool_call(tc) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_one_tool_call(%{"function" => func} = tc) when is_map(func) do
    args_raw = func["arguments"]

    with {:ok, id} <- require_string(tc["id"], "tool_call.id", tc),
         {:ok, name} <- require_string(func["name"], "tool_call.function.name", tc) do
      case decode_arguments(args_raw) do
        {:ok, args} ->
          {:ok,
           %{
             id: id,
             name: name,
             arguments: args
           }}

        {:error, reason} ->
          {:error, {:bad_tool_arguments, reason, args_raw}}
      end
    end
  end

  defp parse_one_tool_call(tc) do
    {:error, {:malformed_response, "tool_call missing function key", tc}}
  end

  defp decode_arguments(args) when is_map(args), do: {:ok, args}

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:arguments_must_decode_to_object, decoded}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_arguments(other), do: {:error, {:unexpected_type, other}}

  defp require_string(value, _field, _context) when is_binary(value) and value != "",
    do: {:ok, value}

  defp require_string(_value, field, context) do
    {:error, {:malformed_response, "#{field} missing or invalid", context}}
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, "tools", tools)

  defp resolve_api_key(opts) do
    case Keyword.get(opts, :api_key) ||
           Application.get_env(:rlm_minimal_ex, :openai_api_key) ||
           System.get_env("OPENAI_API_KEY") do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end
end
