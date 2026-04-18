defmodule RlmMinimalEx.CLITest do
  use ExUnit.Case, async: true

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

  defp scripted_io(opts) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          gets: Keyword.get(opts, :gets, []),
          puts: []
        }
      end)

    io = %{
      puts: fn message ->
        Agent.update(agent, fn state ->
          update_in(state.puts, &[message | &1])
        end)
      end,
      gets: fn _prompt ->
        Agent.get_and_update(agent, fn
          %{gets: [next | rest]} = state -> {next, %{state | gets: rest}}
          state -> {nil, state}
        end)
      end
    }

    get_output = fn ->
      agent
      |> Agent.get(&Enum.reverse(&1.puts))
      |> Enum.join("\n")
    end

    {io, get_output}
  end

  test "interactive mode runs pasted context with multiline content and exits" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "example answer", completed_run(query, "example answer", tokens: 22)}
    end

    {io, get_output} =
      scripted_io(
        gets: [
          "1\n",
          "alpha\n",
          "\n",
          "middle line\n",
          "omega\n",
          "/done\n",
          "What is in the example context?\n",
          "4\n"
        ]
      )

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    assert_receive {:run_called, "alpha\n\nmiddle line\nomega\n",
                    "What is in the example context?", []}

    output = get_output.()

    assert output =~ "How do you want to provide context?"
    assert output =~ "Paste your context below."
    assert output =~ "Type /done on its own line, then press Enter."
    assert output =~ "Answer:"
    assert output =~ "example answer"
    assert output =~ "Status: completed"
    assert output =~ "Tokens: 22"
  end

  test "interactive mode explains Ctrl+D paste termination and exits cleanly" do
    {io, get_output} =
      scripted_io(
        gets: [
          "1\n",
          "first pasted line\n"
        ]
      )

    assert :ok = CLI.start(io: io)

    output = get_output.()

    assert output =~ "Paste your context below."
    assert output =~ "Type /done on its own line, then press Enter."
    assert output =~ "Paste ended with Ctrl+D."
    assert output =~ "finish paste with `/done`"
    refute output =~ "What do you want to ask?"
  end

  test "interactive mode can treat unexpected first input as pasted context" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "done", completed_run(query, "done")}
    end

    {io, _get_output} =
      scripted_io(
        gets: [
          "first context line\n",
          "second context line\n",
          "/done\n",
          "what matters?\n",
          "4\n"
        ]
      )

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    assert_receive {:run_called, "first context line\nsecond context line\n", "what matters?", []}
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

    {io, _get_output} =
      scripted_io(gets: ["2\n", "#{path}\n", "What is in the file?\n", "4\n"])

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    assert_receive {:run_called, "context from file", "What is in the file?", []}

    File.rm_rf!(tmp_dir)
  end

  test "interactive mode can ask another question about the same context" do
    parent = self()

    run_fun = fn context, query, opts ->
      send(parent, {:run_called, context, query, opts})
      {:ok, "answer for #{query}", completed_run(query, "answer for #{query}")}
    end

    {io, _get_output} =
      scripted_io(
        gets: [
          "1\n",
          "shared context\n",
          "/done\n",
          "first question\n",
          "1\n",
          "second question\n",
          "4\n"
        ]
      )

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    assert_receive {:run_called, "shared context\n", "first question", []}
    assert_receive {:run_called, "shared context\n", "second question", []}
  end

  test "interactive mode shows timeline on demand" do
    run_fun = fn _context, query, _opts ->
      {:ok, "done", completed_run(query, "done", tokens: 33)}
    end

    {io, get_output} =
      scripted_io(gets: ["1\n", "context\n", "/done\n", "show me the trace\n", "2\n", "4\n"])

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    output = get_output.()

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

    {io, get_output} =
      scripted_io(gets: ["1\n", "context\n", "/done\n", "why did this fail?\n", "3\n"])

    assert :ok = CLI.start(run_fun: run_fun, io: io)

    output = get_output.()

    assert output =~ "Run failed:"
    assert output =~ ":missing_api_key"
    assert output =~ "What next?"
  end
end
