defmodule RlmMinimalEx.ChatSessionTest do
  use ExUnit.Case, async: true

  alias RlmMinimalEx.ChatSession
  alias RlmMinimalEx.Trajectory.{ModelCall, Run, Step}

  defp completed_run(query, answer) do
    model_call = %ModelCall{
      model: "test",
      messages_in: 2,
      tools_offered: [],
      tool_calls_made: [],
      response_type: :text,
      input_tokens: 10,
      output_tokens: 5,
      duration_ms: 1
    }

    step = %Step{
      path: [0],
      turn: 0,
      model_call: model_call,
      assistant_text: answer,
      actions: [],
      duration_ms: 1
    }

    Run.new(query)
    |> Run.add_step(step)
    |> Map.put(:total_tokens, 15)
    |> Run.complete(answer)
  end

  test "ask/2 carries prior turns into follow-up runs" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} = ChatSession.start(context: "shared context", run_fun: run_fun)
    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:ok, "answer for first question", first_run} =
             ChatSession.ask(session, "first question")

    assert first_run.query == "first question"

    assert {:ok, "answer for second question", second_run} =
             ChatSession.ask(session, "second question")

    assert second_run.query == "second question"

    assert_receive {:run_called, "shared context", "first question", []}
    assert_receive {:run_called, "shared context", "second question", second_opts}

    assert Keyword.get(second_opts, :conversation_history) == [
             %{role: :user, content: "first question"},
             %{role: :assistant, content: "answer for first question"}
           ]
  end

  test "runs/1 and last_run/1 return chronological session history" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} = ChatSession.start(context: "shared context", run_fun: run_fun)
    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:ok, _, _} = ChatSession.ask(session, "first question")
    assert {:ok, _, second_run} = ChatSession.ask(session, "second question")

    assert [%Run{query: "first question"}, %Run{query: "second question"}] =
             ChatSession.runs(session)

    assert %Run{query: "second question"} = ChatSession.last_run(session)
    assert second_run.query == "second question"
  end

  test "update_context/2 clears prior transcript before the next run" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} = ChatSession.start(context: "old context", run_fun: run_fun)
    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:ok, _, _} = ChatSession.ask(session, "first question")
    assert :ok = ChatSession.update_context(session, "new context")
    assert {:ok, _, _} = ChatSession.ask(session, "second question")

    assert_receive {:run_called, "old context", "first question", []}
    assert_receive {:run_called, "new context", "second question", []}
    assert [%Run{query: "second question"}] = ChatSession.runs(session)
  end

  test "retains only the most recent runs and reports dropped count" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} =
      ChatSession.start(context: "shared context", run_fun: run_fun, max_runs: 3)

    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    for query <- ~w[first second third fourth fifth] do
      assert {:ok, _, _} = ChatSession.ask(session, query)
    end

    assert [
             %Run{query: "third"},
             %Run{query: "fourth"},
             %Run{query: "fifth"}
           ] = ChatSession.runs(session)

    assert %Run{query: "fifth"} = ChatSession.last_run(session)

    assert %{
             max_runs: 3,
             run_count: 3,
             dropped_run_count: 2
           } = ChatSession.status(session)
  end

  test "failed runs also count toward the retained run cap" do
    run_fun = fn _context, query, _opts ->
      {:error, {:boom, query},
       completed_run(query, "failed #{query}") |> Map.put(:status, :failed)}
    end

    {:ok, session} =
      ChatSession.start(context: "shared context", run_fun: run_fun, max_runs: 2)

    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:error, {:boom, "first"}, %Run{query: "first", status: :failed}} =
             ChatSession.ask(session, "first")

    assert {:error, {:boom, "second"}, %Run{query: "second", status: :failed}} =
             ChatSession.ask(session, "second")

    assert {:error, {:boom, "third"}, %Run{query: "third", status: :failed}} =
             ChatSession.ask(session, "third")

    assert [%Run{query: "second"}, %Run{query: "third"}] = ChatSession.runs(session)

    assert %{run_count: 2, dropped_run_count: 1} = ChatSession.status(session)
  end

  test "reset/1 clears retained runs and dropped run count" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} =
      ChatSession.start(context: "shared context", run_fun: run_fun, max_runs: 2)

    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:ok, _, _} = ChatSession.ask(session, "first")
    assert {:ok, _, _} = ChatSession.ask(session, "second")
    assert {:ok, _, _} = ChatSession.ask(session, "third")

    assert %{run_count: 2, dropped_run_count: 1} = ChatSession.status(session)

    assert :ok = ChatSession.reset(session)

    assert [] = ChatSession.runs(session)
    assert nil == ChatSession.last_run(session)
    assert %{run_count: 0, dropped_run_count: 0} = ChatSession.status(session)
  end

  test "update_context/2 clears retained runs and dropped run count" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, session} =
      ChatSession.start(context: "old context", run_fun: run_fun, max_runs: 2)

    on_exit(fn -> if Process.alive?(session), do: ChatSession.stop(session) end)

    assert {:ok, _, _} = ChatSession.ask(session, "first")
    assert {:ok, _, _} = ChatSession.ask(session, "second")
    assert {:ok, _, _} = ChatSession.ask(session, "third")

    assert %{run_count: 2, dropped_run_count: 1} = ChatSession.status(session)

    assert :ok = ChatSession.update_context(session, "new context")

    assert [] = ChatSession.runs(session)
    assert nil == ChatSession.last_run(session)

    assert %{run_count: 0, dropped_run_count: 0, context_loaded?: true} =
             ChatSession.status(session)
  end
end
