defmodule RlmMinimalEx.SessionTest do
  use ExUnit.Case, async: true

  alias RlmMinimalEx.{Environment, Session}
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

  defp tool_then_text_model(tool_name, tool_args, final_text) do
    call_count = :counters.new(1, [:atomics])

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

      n = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      if n == 0 do
        call = %{
          id: "call_test_1",
          name: tool_name,
          arguments: tool_args
        }

        {:ok, :tool_calls, [call],
         %{mc | response_type: :tool_calls, tool_calls_made: [tool_name]}}
      else
        {:ok, :text, final_text, mc}
      end
    end
  end

  defp error_model(reason) do
    fn _model, _messages, _opts ->
      {:error, reason}
    end
  end

  defp always_tool_model do
    fn _model, _messages, _opts ->
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

      call = %{
        id: "call_#{System.unique_integer([:positive])}",
        name: "read_var",
        arguments: %{"name" => "context"}
      }

      {:ok, :tool_calls, [call], mc}
    end
  end

  defp delegate_then_text_model(subtask_text, final_text) do
    call_count = :counters.new(1, [:atomics])

    fn _model, messages, _opts ->
      mc = %ModelCall{
        model: "test",
        messages_in: length(messages),
        tools_offered: [],
        tool_calls_made: [],
        response_type: :text,
        input_tokens: 10,
        output_tokens: 5,
        duration_ms: 1
      }

      n = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      case n do
        0 ->
          call = %{
            id: "call_delegate_1",
            name: "delegate_subtask",
            arguments: %{"task" => subtask_text}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

        _ ->
          {:ok, :text, final_text, mc}
      end
    end
  end

  setup do
    {:ok, env} =
      Environment.start_link(
        context: "The magic number is 42.",
        query: "What is the magic number?",
        lane: :read_only
      )

    %{env: env}
  end

  test "text response finalizes immediately", %{env: env} do
    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: text_model("The answer is 42."), max_turns: 5)

    assert {:ok, "The answer is 42.", run} = Session.run(session, "What is the magic number?")
    assert run.status == :completed
    assert length(run.steps) == 1
    assert run.total_tokens > 0
  end

  test "tool call then text answer", %{env: env} do
    model_fn = tool_then_text_model("read_var", %{"name" => "context"}, "42")

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "42", run} = Session.run(session, "What is the magic number?")
    assert run.status == :completed
    assert length(run.steps) == 2

    [step1, step2] = run.steps
    assert length(step1.actions) == 1
    assert hd(step1.actions).name == :read_var
    assert step2.actions == []
  end

  test "model error returns error tuple", %{env: env} do
    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: error_model(:timeout), max_turns: 5)

    assert {:error, :timeout, run} = Session.run(session, "test")
    assert run.status == :failed
  end

  test "max turns triggers fallback", %{env: env} do
    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: always_tool_model(), max_turns: 2)

    assert {:ok, _answer, run} = Session.run(session, "test")
    assert run.status == :completed
    assert length(run.steps) == 2
  end

  test "delegate_subtask uses Task.Supervisor", %{env: env} do
    model_fn = delegate_then_text_model("What is 2+2?", "4")

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "4", run} = Session.run(session, "Delegate something")
    assert run.status == :completed

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert delegate_action.executor == :session
  end

  test "delegate_subtask survives worker crash", %{env: env} do
    crashing_model = fn _model, messages, _opts ->
      mc = %ModelCall{
        model: "test",
        messages_in: length(messages),
        tools_offered: [],
        tool_calls_made: [],
        response_type: :text,
        input_tokens: 10,
        output_tokens: 5,
        duration_ms: 1
      }

      is_worker =
        Enum.any?(messages, fn
          %{"content" => c} when is_binary(c) -> String.contains?(c, "focused worker")
          _ -> false
        end)

      if is_worker do
        raise "worker exploded!"
      else
        if length(messages) <= 3 do
          call = %{
            id: "call_crash_1",
            name: "delegate_subtask",
            arguments: %{"task" => "crash me"}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}
        else
          {:ok, :text, "recovered", mc}
        end
      end
    end

    {:ok, session} = Session.start_link(env_pid: env, model_fn: crashing_model, max_turns: 5)

    assert {:ok, "recovered", run} = Session.run(session, "Do something risky")
    assert run.status == :completed

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert delegate_action.result =~ "ERROR"
  end
end
