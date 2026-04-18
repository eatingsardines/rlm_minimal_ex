defmodule RlmMinimalEx.DiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias RlmMinimalEx.{ChatSession, Diagnostics, Environment, RunSupervisor, Session}
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

  test "diagnostics snapshot reports live chat sessions and run trees" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, chat_session} = ChatSession.start(context: "shared context", run_fun: run_fun)
    on_exit(fn -> if Process.alive?(chat_session), do: ChatSession.stop(chat_session) end)

    {:ok, run_sup} =
      DynamicSupervisor.start_child(
        RlmMinimalEx.RunsSupervisor,
        {RunSupervisor,
         context: "context body",
         query: "What is the magic number?",
         lane: :read_only,
         model_fn: fn _model, _messages, _opts ->
           {:error, :skip}
         end}
      )

    on_exit(fn ->
      if Process.alive?(run_sup) do
        DynamicSupervisor.terminate_child(RlmMinimalEx.RunsSupervisor, run_sup)
      end
    end)

    session_pid = RunSupervisor.session(run_sup)
    env_pid = RunSupervisor.environment(run_sup)
    task_sup_pid = RunSupervisor.task_supervisor(run_sup)

    assert is_pid(session_pid)
    assert is_pid(env_pid)
    assert is_pid(task_sup_pid)

    chat_snapshot = Diagnostics.chat_snapshot(chat_session)
    assert chat_snapshot.process.pid == chat_session
    assert chat_snapshot.status.busy? == false
    assert chat_snapshot.status.context_loaded? == true

    run_snapshot = Diagnostics.run_snapshot(run_sup)
    assert run_snapshot.supervisor.pid == run_sup
    assert run_snapshot.session.pid == session_pid
    assert run_snapshot.environment.pid == env_pid
    assert run_snapshot.task_supervisor.pid == task_sup_pid

    assert run_snapshot.session_status == Session.status(session_pid)
    assert run_snapshot.environment_status == Environment.status(env_pid)

    snapshot = Diagnostics.snapshot()
    assert Enum.any?(snapshot.chats, &(&1.process.pid == chat_session))
    assert Enum.any?(snapshot.runs, &(&1.supervisor.pid == run_sup))
  end

  test "mix rlm.diagnostics prints live snapshot output" do
    run_fun = fn _context, query, _opts ->
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {:ok, chat_session} = ChatSession.start(context: "shared context", run_fun: run_fun)
    on_exit(fn -> if Process.alive?(chat_session), do: ChatSession.stop(chat_session) end)

    Mix.Task.reenable("rlm.diagnostics")

    output =
      capture_io(fn ->
        Mix.Tasks.Rlm.Diagnostics.run([])
      end)

    assert output =~ "RlmMinimalEx diagnostics"
    assert output =~ "Active chats:"
    assert output =~ "Active runs:"
  end
end
