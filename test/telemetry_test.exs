defmodule RlmMinimalEx.TelemetryTest do
  use ExUnit.Case, async: false

  alias RlmMinimalEx.{Environment, Session}
  alias RlmMinimalEx.Trajectory.ModelCall

  defp attach_telemetry(events) do
    handler_id = "rlm-minimal-ex-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_telemetry_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp text_model(text) do
    fn model, messages, _opts ->
      mc = %ModelCall{
        model: model,
        messages_in: length(messages),
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

  defp delegate_then_text_model(subtask_text, final_text) do
    call_count = :counters.new(1, [:atomics])

    fn model, messages, _opts ->
      mc = %ModelCall{
        model: model,
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
          %{"content" => content} when is_binary(content) ->
            String.contains?(content, "focused worker agent")

          _ ->
            false
        end)

      cond do
        is_worker ->
          {:ok, :text, "worker answer", mc}

        :counters.get(call_count, 1) == 0 ->
          :counters.add(call_count, 1, 1)

          call = %{
            id: "call_delegate_1",
            name: "delegate_subtask",
            arguments: %{"task" => subtask_text}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

        true ->
          {:ok, :text, final_text, mc}
      end
    end
  end

  test "run and model calls emit telemetry events" do
    attach_telemetry([
      [:rlm_minimal_ex, :run, :start],
      [:rlm_minimal_ex, :run, :stop],
      [:rlm_minimal_ex, :model, :call, :stop]
    ])

    assert {:ok, "done", run} =
             RlmMinimalEx.run("The magic number is 42.", "What is the answer?",
               model_fn: text_model("done")
             )

    assert run.status == :completed

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :run, :start], start_measurements,
                    start_metadata}

    assert is_integer(start_measurements.system_time)
    assert start_metadata.lane == :read_only
    assert start_metadata.context_loaded? == true

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :model, :call, :stop], model_measurements,
                    model_metadata}

    assert model_measurements.duration_ms >= 0
    assert model_metadata.status == :ok
    assert model_metadata.response_type == :text
    assert model_metadata.messages_in == 2

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :run, :stop], stop_measurements,
                    stop_metadata}

    assert stop_measurements.duration_ms >= 0
    assert stop_metadata.status == :completed
    assert stop_metadata.total_tokens > 0
  end

  test "environment actions emit action and line cache telemetry" do
    attach_telemetry([
      [:rlm_minimal_ex, :environment, :action, :stop],
      [:rlm_minimal_ex, :environment, :line_cache]
    ])

    {:ok, env} =
      Environment.start_link(
        context: "alpha\nbeta\ngamma",
        query: "Find beta",
        lane: :read_only
      )

    assert {:ok, "L1: alpha\nL2: beta"} =
             Environment.execute(env, :read_lines, %{
               "source" => "context",
               "start_line" => 1,
               "end_line" => 2
             })

    assert {:ok, "L2: beta\nL3: gamma"} =
             Environment.execute(env, :read_lines, %{
               "source" => "context",
               "start_line" => 2,
               "end_line" => 3
             })

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :environment, :line_cache], %{count: 1},
                    %{status: :hit, var: "context"}}

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :environment, :action, :stop],
                    action_measurements, %{action: :read_lines, status: :ok}}

    assert action_measurements.duration_ms >= 0

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :environment, :line_cache], %{count: 1},
                    %{status: :hit, var: "context"}}

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :environment, :action, :stop],
                    %{duration_ms: _duration_ms}, %{action: :read_lines, status: :ok}}
  end

  test "delegation emits telemetry with child outcome" do
    attach_telemetry([
      [:rlm_minimal_ex, :delegate, :stop]
    ])

    {:ok, env} =
      Environment.start_link(
        context: "The magic number is 42.",
        query: "Delegate something",
        lane: :read_only
      )

    {:ok, session} =
      Session.start_link(
        env_pid: env,
        model_fn: delegate_then_text_model("What is 2+2?", "4"),
        max_turns: 5
      )

    assert {:ok, "4", run} = Session.run(session, "Delegate something")
    assert run.status == :completed

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :delegate, :stop], measurements, metadata}

    assert measurements.duration_ms >= 0
    assert metadata.status == :ok
    assert metadata.context_var == "context"
    assert metadata.child_status == :completed
    assert metadata.child_tokens > 0
  end

  test "blocked delegation emits blocked telemetry metadata" do
    attach_telemetry([
      [:rlm_minimal_ex, :delegate, :stop]
    ])

    {:ok, env} =
      Environment.start_link(
        context: "The magic number is 42.",
        query: "Delegate something",
        lane: :read_only
      )

    worker_count = :counters.new(1, [:atomics])
    top_level_count = :counters.new(1, [:atomics])

    model_fn = fn model, messages, _opts ->
      mc = %ModelCall{
        model: model,
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
          %{"content" => content} when is_binary(content) ->
            String.contains?(content, "focused worker agent")

          _ ->
            false
        end)

      cond do
        is_worker and :counters.get(worker_count, 1) == 0 ->
          :counters.add(worker_count, 1, 1)

          call = %{
            id: "call_delegate_depth_block",
            name: "delegate_subtask",
            arguments: %{"task" => "nested worker"}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

        is_worker ->
          {:ok, :text, "worker answer", mc}

        :counters.get(top_level_count, 1) == 0 ->
          :counters.add(top_level_count, 1, 1)

          call = %{
            id: "call_top_level_delegate",
            name: "delegate_subtask",
            arguments: %{"task" => "worker task"}
          }

          {:ok, :tool_calls, [call],
           %{mc | response_type: :tool_calls, tool_calls_made: ["delegate_subtask"]}}

        true ->
          {:ok, :text, "top level finished", mc}
      end
    end

    {:ok, session} =
      Session.start_link(
        env_pid: env,
        model_fn: model_fn,
        max_turns: 5,
        max_delegate_depth: 1
      )

    assert {:ok, "top level finished", run} = Session.run(session, "Delegate once")
    assert run.status == :completed

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :delegate, :stop], %{duration_ms: _},
                    %{status: :ok}}

    assert_receive {:telemetry_event, [:rlm_minimal_ex, :delegate, :stop], %{duration_ms: _},
                    blocked_metadata}

    assert blocked_metadata.status == :blocked
    assert blocked_metadata.reason =~ "max delegate depth reached"
    assert blocked_metadata.context_var == "context"
    assert blocked_metadata.child_status == nil
  end
end
