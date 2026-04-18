defmodule RlmMinimalEx.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias RlmMinimalEx.CLI
  alias RlmMinimalEx.Trajectory.{ModelCall, Run, Step}

  defp completed_run(query, answer, opts \\ []) do
    model_call = %ModelCall{
      model: "test",
      messages_in: 2,
      tools_offered: [],
      tool_calls_made: [],
      response_type: Keyword.get(opts, :response_type, :text),
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
    |> Map.put(:total_tokens, Keyword.get(opts, :tokens, 15))
    |> Run.complete(answer)
  end

  test "interactive mode runs pasted context and exits" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "ORCHID-9137-DELTA", completed_run(query, "ORCHID-9137-DELTA", tokens: 22)}
    end

    input = """
    1
    alpha
    sentinel token: ORCHID-9137-DELTA
    omega

    Find the sentinel token.
    4
    """

    output =
      capture_io(input, fn ->
        assert :ok = CLI.start(run_fun: run_fun)
      end)

    assert_receive {:run_called, "alpha\nsentinel token: ORCHID-9137-DELTA\nomega\n",
                    "Find the sentinel token.", []}

    assert output =~ "How do you want to provide context?"
    assert output =~ "Paste your context below."
    assert output =~ "Answer:"
    assert output =~ "ORCHID-9137-DELTA"
    assert output =~ "Status: completed"
    assert output =~ "Tokens: 22"
  end

  test "interactive mode can load context from file" do
    parent = self()
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_cli_test_#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "context.txt")
    File.write!(path, "context from file")

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "done", completed_run(query, "done")}
    end

    input = """
    2
    #{path}
    What is in the file?
    4
    """

    capture_io(input, fn ->
      assert :ok = CLI.start(run_fun: run_fun)
    end)

    assert_receive {:run_called, "context from file", "What is in the file?", []}

    File.rm_rf!(tmp_dir)
  end

  test "interactive mode can ask another question about the same context" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    input = """
    1
    shared context

    first question
    1
    second question
    4
    """

    capture_io(input, fn ->
      assert :ok = CLI.start(run_fun: run_fun)
    end)

    assert_receive {:run_called, "shared context\n", "first question", []}
    assert_receive {:run_called, "shared context\n", "second question", []}
  end

  test "interactive mode shows timeline on demand" do
    run_fun = fn _context, query, _opts ->
      {:ok, "done", completed_run(query, "done", tokens: 33)}
    end

    input = """
    1
    context

    show me the trace
    2
    4
    """

    output =
      capture_io(input, fn ->
        assert :ok = CLI.start(run_fun: run_fun)
      end)

    assert output =~ "Run status=completed total_tokens=33"
    assert output =~ "Query: show me the trace"
    assert output =~ "Answer: done"
    assert output =~ "[0] turn=0 response=text model=test"
    assert output =~ "assistant:"
    assert output =~ "done"
  end

  test "interactive mode prints friendly errors and lets the user exit" do
    run_fun = fn _context, _query, _opts ->
      {:error, :missing_api_key}
    end

    input = """
    1
    context

    why did this fail?
    3
    """

    output =
      capture_io(input, fn ->
        assert :ok = CLI.start(run_fun: run_fun)
      end)

    assert output =~ "Run failed:"
    assert output =~ ":missing_api_key"
    assert output =~ "What next?"
  end
end
