defmodule Mix.Tasks.Rlm.ChatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias __MODULE__.CLIStub
  alias Mix.Tasks.Rlm.Chat

  defmodule CLIStub do
    def start(opts) do
      pid = Application.get_env(:rlm_minimal_ex, :cli_test_pid)
      send(pid, {:cli_started, opts})
      :ok
    end
  end

  setup do
    previous_cli_module = Application.get_env(:rlm_minimal_ex, :cli_module)
    previous_test_pid = Application.get_env(:rlm_minimal_ex, :cli_test_pid)

    Application.put_env(:rlm_minimal_ex, :cli_module, CLIStub)
    Application.put_env(:rlm_minimal_ex, :cli_test_pid, self())

    on_exit(fn ->
      if previous_cli_module do
        Application.put_env(:rlm_minimal_ex, :cli_module, previous_cli_module)
      else
        Application.delete_env(:rlm_minimal_ex, :cli_module)
      end

      if previous_test_pid do
        Application.put_env(:rlm_minimal_ex, :cli_test_pid, previous_test_pid)
      else
        Application.delete_env(:rlm_minimal_ex, :cli_test_pid)
      end
    end)

    :ok
  end

  test "mix rlm.chat delegates to the CLI with parsed options" do
    capture_io(fn ->
      Chat.run([
        "--file",
        "context.txt",
        "--model",
        "gpt-test",
        "--workspace",
        "--max-turns",
        "3"
      ])
    end)

    assert_receive {:cli_started, opts}
    assert opts[:file] == "context.txt"
    assert opts[:run_opts][:model] == "gpt-test"
    assert opts[:run_opts][:lane] == :workspace
    assert opts[:run_opts][:max_turns] == 3
  end

  test "mix rlm.chat prints help text" do
    output =
      capture_io(fn ->
        Chat.run(["--help"])
      end)

    assert output =~ "mix rlm.chat"
    assert output =~ "path/to/context.txt"
    assert output =~ "--file"
    assert output =~ "--model"
    assert output =~ "follow-up questions reuse the same context"
    assert output =~ "paste mode ends with `/done`"
    assert output =~ "regular writes require `--workspace`"
    refute_receive {:cli_started, _opts}
  end
end
