defmodule RlmMinimalExTest do
  use ExUnit.Case, async: true

  alias RlmMinimalEx.Trajectory.ModelCall

  defp text_model(text) do
    fn _model, _messages, _opts ->
      mc = %ModelCall{
        model: "test",
        messages_in: 1,
        tools_offered: [],
        tool_calls_made: [],
        response_type: :text,
        input_tokens: 10,
        output_tokens: 5,
        duration_ms: 1
      }

      {:ok, :text, text, mc}
    end
  end

  defp error_model do
    fn _model, _messages, _opts ->
      {:error, :missing_api_key}
    end
  end

  test "run/3 returns {:ok, answer, run}" do
    assert {:ok, "42", run} =
             RlmMinimalEx.run(
               "The answer is 42.",
               "What is the answer?",
               model_fn: text_model("42")
             )

    assert run.status == :completed
    assert run.query == "What is the answer?"
  end

  test "run!/3 returns answer string" do
    assert RlmMinimalEx.run!("ctx", "query", model_fn: text_model("hello")) == "hello"
  end

  test "run!/3 raises on error" do
    assert_raise RuntimeError, ~r/failed/, fn ->
      RlmMinimalEx.run!("ctx", "query", model_fn: error_model())
    end
  end

  test "run/3 returns error tuple on model failure" do
    assert {:error, :missing_api_key, run} =
             RlmMinimalEx.run("ctx", "query", model_fn: error_model())

    assert run.status == :failed
  end

  test "run/3 returns timeout error when max turns are exhausted" do
    call_count = :counters.new(1, [:atomics])

    always_tool_model = fn _model, _messages, _opts ->
      mc = %ModelCall{
        model: "test",
        messages_in: 1,
        tools_offered: [],
        tool_calls_made: ["read_var"],
        response_type: :tool_calls,
        input_tokens: 10,
        output_tokens: 5,
        duration_ms: 1
      }

      call_id = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      call = %{
        id: "call_timeout_#{call_id}",
        name: "read_var",
        arguments: %{"name" => "context"}
      }

      {:ok, :tool_calls, [call], mc}
    end

    assert {:error, :max_turns_exceeded, run} =
             RlmMinimalEx.run("ctx", "query", model_fn: always_tool_model, max_turns: 2)

    assert run.status == :timeout
    assert length(run.steps) == 2
  end

  test "run cleans up processes after completion" do
    RlmMinimalEx.run("ctx", "q", model_fn: text_model("done"))

    assert DynamicSupervisor.which_children(RlmMinimalEx.RunsSupervisor) == []
  end
end
