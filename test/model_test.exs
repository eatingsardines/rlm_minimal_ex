defmodule RlmMinimalEx.ModelTest do
  use ExUnit.Case, async: true

  defp user_messages do
    [%{"role" => "user", "content" => "hi"}]
  end

  defp tool_definitions do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "search_context",
          "description" => "Search the context",
          "parameters" => %{"type" => "object"}
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_var",
          "description" => "Read a variable",
          "parameters" => %{"type" => "object"}
        }
      }
    ]
  end

  test "returns missing_api_key when no key is configured" do
    assert {:error, :missing_api_key} =
             RlmMinimalEx.Model.chat("gpt-test", user_messages(), api_key: nil)
  end

  test "returns text responses with model call metadata" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "hello"}}],
           "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4}
         }
       }}
    end

    assert {:ok, :text, "hello", model_call} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn,
               tools: tool_definitions()
             )

    assert model_call.model == "gpt-test"
    assert model_call.response_type == :text
    assert model_call.tools_offered == ["search_context", "read_var"]
    assert model_call.tool_calls_made == []
    assert model_call.input_tokens == 12
    assert model_call.output_tokens == 4
  end

  test "parses multiple tool calls with string and map arguments" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "content" => nil,
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "function" => %{
                       "name" => "search_context",
                       "arguments" => ~s({"query":"sentinel"})
                     }
                   },
                   %{
                     "id" => "call_2",
                     "function" => %{
                       "name" => "read_var",
                       "arguments" => %{"name" => "context"}
                     }
                   }
                 ]
               }
             }
           ],
           "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 6}
         }
       }}
    end

    assert {:ok, :tool_calls, calls, model_call} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn,
               tools: tool_definitions()
             )

    assert calls == [
             %{id: "call_1", name: "search_context", arguments: %{"query" => "sentinel"}},
             %{id: "call_2", name: "read_var", arguments: %{"name" => "context"}}
           ]

    assert model_call.response_type == :tool_calls
    assert model_call.tool_calls_made == ["search_context", "read_var"]
  end

  test "returns malformed response when provider response has no choices" do
    request_fn = fn _url, _opts ->
      {:ok, %{status: 200, body: %{"id" => "resp_1"}}}
    end

    assert {:error, {:malformed_response, "no choices", _body}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns malformed response when tool call is missing function" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"tool_calls" => [%{"id" => "call_1"}]}}]
         }
       }}
    end

    assert {:error, {:malformed_response, "tool_call missing function key", _tool_call}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns malformed response when tool call id is missing" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "function" => %{
                       "name" => "search_context",
                       "arguments" => ~s({"query":"sentinel"})
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:error, {:malformed_response, "tool_call.id missing or invalid", _context}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns malformed response when tool call name is missing" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "function" => %{
                       "arguments" => ~s({"query":"sentinel"})
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:error, {:malformed_response, "tool_call.function.name missing or invalid", _context}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns bad_tool_arguments when tool arguments are invalid json" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "function" => %{
                       "name" => "search_context",
                       "arguments" => "{not json"
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:error, {:bad_tool_arguments, {:invalid_json, _reason}, "{not json"}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns bad_tool_arguments when decoded arguments are not an object" do
    request_fn = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "function" => %{
                       "name" => "search_context",
                       "arguments" => ~s(["not","an","object"])
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:error,
            {:bad_tool_arguments, {:arguments_must_decode_to_object, ["not", "an", "object"]},
             _args_raw}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns http error on non-200 responses" do
    request_fn = fn _url, _opts ->
      {:ok, %{status: 503, body: %{"error" => %{"message" => "unavailable"}}}}
    end

    assert {:error, {:http, 503, %{"error" => %{"message" => "unavailable"}}}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end

  test "returns transport error when request fails" do
    request_fn = fn _url, _opts ->
      {:error, :nxdomain}
    end

    assert {:error, {:transport, :nxdomain}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               user_messages(),
               api_key: "test-key",
               request_fn: request_fn
             )
  end
end
