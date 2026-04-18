defmodule RlmMinimalEx.SessionTest do
  use ExUnit.Case, async: true

  alias RlmMinimalEx.{Environment, Session}
  alias RlmMinimalEx.Trajectory.{ModelCall, Run}

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

  defp tool_sequence_then_text_model(tool_calls, final_text) do
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

      index = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      case Enum.at(tool_calls, index) do
        nil ->
          {:ok, :text, final_text, mc}

        call ->
          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: [call.name]}}
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

  test "defaults to gpt-5.4-nano when no override is configured", %{env: env} do
    original_env_model = System.get_env("RLM_MINIMAL_EX_MODEL")

    try do
      System.delete_env("RLM_MINIMAL_EX_MODEL")

      {:ok, session} =
        Session.start_link(
          env_pid: env,
          model_fn: text_model("The answer is 42."),
          max_turns: 5
        )

      state = :sys.get_state(session)
      assert state.model_name == "gpt-5.4-nano"
    after
      if original_env_model do
        System.put_env("RLM_MINIMAL_EX_MODEL", original_env_model)
      else
        System.delete_env("RLM_MINIMAL_EX_MODEL")
      end
    end
  end

  test "default system prompt instructs the coordinator to inspect context first", %{env: env} do
    parent = self()

    model_fn = fn _model, messages, _opts ->
      send(parent, {:messages_seen, messages})

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

      {:ok, :text, "done", mc}
    end

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "done", run} = Session.run(session, "What is the magic number?")
    assert run.status == :completed

    assert_receive {:messages_seen,
                    [%{"role" => "system", "content" => system_prompt}, _user_msg]}

    assert system_prompt =~ "read_text_range"
    assert system_prompt =~ "read_lines"
    assert system_prompt =~ "write_scratchpad"
    assert system_prompt =~ "Do not answer until you have inspected the context"
    assert system_prompt =~ "If prior conversation history is present"
  end

  test "initial messages include prior conversation history before the new query", %{env: env} do
    parent = self()

    model_fn = fn _model, messages, _opts ->
      send(parent, {:messages_seen, messages})

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

      {:ok, :text, "done", mc}
    end

    history = [
      %{role: :user, content: "Which section matters most?"},
      %{role: :assistant, content: "The processes section is the closest match."}
    ]

    {:ok, session} =
      Session.start_link(
        env_pid: env,
        model_fn: model_fn,
        max_turns: 5,
        conversation_history: history
      )

    assert {:ok, "done", run} = Session.run(session, "deeper")
    assert run.status == :completed

    assert_receive {:messages_seen,
                    [
                      %{"role" => "system", "content" => _system_prompt},
                      %{"role" => "user", "content" => "Which section matters most?"},
                      %{
                        "role" => "assistant",
                        "content" => "The processes section is the closest match."
                      },
                      %{"role" => "user", "content" => "deeper"}
                    ]}
  end

  test "delegated workers do not inherit prior conversation history", %{env: env} do
    parent = self()
    call_count = :counters.new(1, [:atomics])

    model_fn = fn _model, messages, _opts ->
      system_prompt = hd(messages)["content"]

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

      if String.contains?(system_prompt, "focused worker agent") do
        send(parent, {:worker_messages_seen, messages})
        {:ok, :text, "worker answer", mc}
      else
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 ->
            call = %{
              id: "call_delegate_1",
              name: "delegate_subtask",
              arguments: %{"task" => "subtask"}
            }

            {:ok, :tool_calls, [call],
             %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

          _ ->
            {:ok, :text, "top level answer", mc}
        end
      end
    end

    history = [
      %{role: :user, content: "Which section matters most?"},
      %{role: :assistant, content: "The processes section is the closest match."}
    ]

    {:ok, session} =
      Session.start_link(
        env_pid: env,
        model_fn: model_fn,
        max_turns: 5,
        conversation_history: history
      )

    assert {:ok, "top level answer", run} = Session.run(session, "deeper")
    assert run.status == :completed

    assert_receive {:worker_messages_seen,
                    [
                      %{"role" => "system", "content" => worker_prompt},
                      %{"role" => "user", "content" => "subtask"}
                    ]}

    assert worker_prompt =~ "focused worker agent"
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

  test "slice_text can create and reuse a stored chunk in one run", %{env: env} do
    model_fn =
      tool_sequence_then_text_model(
        [
          %{
            id: "call_slice_1",
            name: "slice_text",
            arguments: %{
              "source" => "context",
              "offset" => 4,
              "length" => 15,
              "target" => "focus_chunk"
            }
          },
          %{
            id: "call_read_2",
            name: "read_var",
            arguments: %{"name" => "focus_chunk"}
          }
        ],
        "The answer is still 42."
      )

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "The answer is still 42.", run} = Session.run(session, "Inspect a chunk first")
    assert run.status == :completed
    assert length(run.steps) == 3

    [step1, step2, step3] = run.steps
    assert hd(step1.actions).name == :slice_text
    assert hd(step1.actions).result =~ "Stored 'focus_chunk' (15 chars) from 'context'"
    assert hd(step1.actions).result =~ "Content:\nmagic number is"

    assert hd(step2.actions).name == :read_var
    assert hd(step2.actions).result =~ "focus_chunk = magic number is"

    assert step3.actions == []
  end

  test "write_scratchpad can persist intermediate coordinator state in read_only lane", %{
    env: env
  } do
    model_fn =
      tool_sequence_then_text_model(
        [
          %{
            id: "call_scratch_1",
            name: "write_scratchpad",
            arguments: %{
              "name" => "summary",
              "value" => "The magic number appears to be 42."
            }
          },
          %{
            id: "call_read_2",
            name: "read_var",
            arguments: %{"name" => "scratch:summary"}
          }
        ],
        "42"
      )

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "42", run} =
             Session.run(session, "Store an intermediate summary before answering")

    assert run.status == :completed
    assert length(run.steps) == 3

    [step1, step2, step3] = run.steps
    assert hd(step1.actions).name == :write_scratchpad
    assert hd(step1.actions).result =~ "Stored scratch 'summary' as 'scratch:summary'"

    assert hd(step2.actions).name == :read_var
    assert hd(step2.actions).result =~ "scratch:summary = The magic number appears to be 42."

    assert step3.actions == []
  end

  test "model error returns error tuple", %{env: env} do
    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: error_model(:timeout), max_turns: 5)

    assert {:error, :timeout, run} = Session.run(session, "test")
    assert run.status == :failed
  end

  test "max turns returns timeout error", %{env: env} do
    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: always_tool_model(), max_turns: 2)

    assert {:error, :max_turns_exceeded, run} = Session.run(session, "test")
    assert run.status == :timeout
    assert length(run.steps) == 2
  end

  test "delegate_subtask uses Task.Supervisor", %{env: env} do
    model_fn = delegate_then_text_model("What is 2+2?", "4")

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "4", run} = Session.run(session, "Delegate something")
    assert run.status == :completed

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert length(run.root_steps) == 2
    assert length(run.steps) == 3
    assert Enum.at(run.steps, 1).path == [0, 0, 0]
    assert length(Run.delegate_steps(run)) == 1
    assert Run.pretty_timeline(run) =~ "[0] turn=0 tool_calls actions=[delegate_subtask]"
    assert Run.pretty_timeline(run) =~ "[0.0.0] turn=0 text"
    assert delegate_action.executor == :session
    assert delegate_action.child_run.status == :completed
    assert delegate_action.child_run.answer == "4"
  end

  test "delegate_subtask runs a nested worker session against scoped context beyond 4 KB" do
    sentinel = "ORCHID-SENTINEL-9001"
    large_context = String.duplicate("a", 5_000) <> sentinel

    {:ok, env} =
      Environment.start_link(
        context: large_context,
        query: "Find the sentinel",
        lane: :read_only
      )

    parent = self()
    call_count = :counters.new(1, [:atomics])

    model_fn = fn _model, messages, _opts ->
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

      has_tool_result =
        Enum.any?(messages, fn
          %{"role" => "tool", "content" => c} when is_binary(c) -> String.contains?(c, sentinel)
          _ -> false
        end)

      cond do
        is_worker and has_tool_result ->
          send(parent, {:worker_followup_messages, messages})

          {:ok, :text, "worker saw sentinel", mc}

        is_worker ->
          send(parent, {:worker_initial_messages, messages})

          call = %{
            id: "call_worker_search",
            name: "search_context",
            arguments: %{"query" => sentinel}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["search_context"]}}

        true ->
          n = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)

          case n do
            0 ->
              call = %{
                id: "call_delegate_full_context",
                name: "delegate_subtask",
                arguments: %{
                  "task" => "Find the sentinel",
                  "context_var" => "context"
                }
              }

              {:ok, :tool_calls, [call],
               %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

            _ ->
              {:ok, :text, "delegated", mc}
          end
      end
    end

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5)

    assert {:ok, "delegated", run} = Session.run(session, "Use a worker to inspect the context")
    assert run.status == :completed

    assert_receive {:worker_initial_messages, worker_initial_messages}

    refute Enum.any?(worker_initial_messages, fn
             %{"content" => c} when is_binary(c) -> String.contains?(c, sentinel)
             _ -> false
           end)

    assert_receive {:worker_followup_messages, worker_followup_messages}

    assert Enum.any?(worker_followup_messages, fn
             %{"role" => "tool", "content" => c} when is_binary(c) ->
               String.contains?(c, sentinel)

             _ ->
               false
           end)

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert length(run.root_steps) == 2
    assert length(run.steps) == 4
    assert Enum.at(run.steps, 1).path == [0, 0, 0]
    assert Enum.at(run.steps, 2).path == [0, 0, 1]
    assert length(Run.delegate_steps(run)) == 2
    assert Run.pretty_timeline(run) =~ "[0.0.0] turn=0 tool_calls actions=[search_context]"
    assert Run.pretty_timeline(run) =~ "[0.0.1] turn=1 text"
    assert delegate_action.result == "worker saw sentinel"
    assert delegate_action.child_run.status == :completed
    assert delegate_action.child_run.answer == "worker saw sentinel"
    assert length(delegate_action.child_run.steps) == 2

    assert hd(delegate_action.child_run.steps).actions |> hd() |> Map.get(:name) ==
             :search_context
  end

  test "delegate_subtask can scope a nested worker to a large stored variable beyond 4 KB" do
    sentinel = "SCOPED-VAR-SENTINEL-77"

    {:ok, env} =
      Environment.start_link(
        context: "outer context",
        query: "Find the sentinel",
        lane: :workspace
      )

    assert {:ok, _content} =
             Environment.execute(env, :write_var, %{
               "name" => "focus_chunk",
               "value" => String.duplicate("b", 5_000) <> sentinel
             })

    parent = self()
    call_count = :counters.new(1, [:atomics])

    model_fn = fn _model, messages, _opts ->
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

      has_tool_result =
        Enum.any?(messages, fn
          %{"role" => "tool", "content" => c} when is_binary(c) -> String.contains?(c, sentinel)
          _ -> false
        end)

      cond do
        is_worker and has_tool_result ->
          send(parent, {:scoped_worker_followup_messages, messages})
          {:ok, :text, "worker saw scoped sentinel", mc}

        is_worker ->
          send(parent, {:scoped_worker_initial_messages, messages})

          call = %{
            id: "call_worker_scoped_search",
            name: "search_context",
            arguments: %{"query" => sentinel}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["search_context"]}}

        true ->
          n = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)

          case n do
            0 ->
              call = %{
                id: "call_delegate_scoped_var",
                name: "delegate_subtask",
                arguments: %{
                  "task" => "Find the sentinel in the scoped chunk",
                  "context_var" => "focus_chunk"
                }
              }

              {:ok, :tool_calls, [call],
               %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

            _ ->
              {:ok, :text, "delegated via scoped var", mc}
          end
      end
    end

    {:ok, session} =
      Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 5, lane: :workspace)

    assert {:ok, "delegated via scoped var", run} =
             Session.run(session, "Use a worker on the scoped chunk")

    assert run.status == :completed

    assert_receive {:scoped_worker_initial_messages, scoped_worker_initial_messages}

    refute Enum.any?(scoped_worker_initial_messages, fn
             %{"content" => c} when is_binary(c) -> String.contains?(c, sentinel)
             _ -> false
           end)

    assert_receive {:scoped_worker_followup_messages, scoped_worker_followup_messages}

    assert Enum.any?(scoped_worker_followup_messages, fn
             %{"role" => "tool", "content" => c} when is_binary(c) ->
               String.contains?(c, sentinel)

             _ ->
               false
           end)

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert delegate_action.result == "worker saw scoped sentinel"
  end

  test "delegate_subtask surfaces nested worker timeout as an action error", %{env: env} do
    call_count = :counters.new(1, [:atomics])

    model_fn = fn _model, messages, _opts ->
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
        call = %{
          id: "call_worker_timeout",
          name: "read_var",
          arguments: %{"name" => "context"}
        }

        {:ok, :tool_calls, [call],
         %{mc | response_type: :tool_calls, tool_calls_made: ["read_var"]}}
      else
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 ->
            call = %{
              id: "call_delegate_timeout",
              name: "delegate_subtask",
              arguments: %{"task" => "Keep reading forever"}
            }

            {:ok, :tool_calls, [call],
             %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

          _ ->
            {:ok, :text, "outer recovered", mc}
        end
      end
    end

    {:ok, session} = Session.start_link(env_pid: env, model_fn: model_fn, max_turns: 2)

    assert {:ok, "outer recovered", run} = Session.run(session, "Delegate and recover")
    assert run.status == :completed

    [step1 | _] = run.steps
    delegate_action = Enum.find(step1.actions, &(&1.name == :delegate_subtask))
    assert delegate_action.result =~ "ERROR: Delegation failed: :max_turns_exceeded"
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
    assert delegate_action.result =~ "Worker crashed"
    assert delegate_action.result =~ "worker exploded!"
  end
end
