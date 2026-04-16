defmodule RlmMinimalEx.ModelTest do
  use ExUnit.Case, async: true

  test "returns missing_api_key when no key is configured" do
    assert {:error, :missing_api_key} =
             RlmMinimalEx.Model.chat("gpt-test", [%{"role" => "user", "content" => "hi"}],
               api_key: nil
             )
  end

  test "returns malformed response when provider response has no choices" do
    request_fn = fn _url, _opts ->
      {:ok, %{status: 200, body: %{"id" => "resp_1"}}}
    end

    assert {:error, {:malformed_response, "no choices", _body}} =
             RlmMinimalEx.Model.chat(
               "gpt-test",
               [%{"role" => "user", "content" => "hi"}],
               api_key: "test-key",
               request_fn: request_fn
             )
  end
end
