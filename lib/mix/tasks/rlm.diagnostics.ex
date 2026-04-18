defmodule Mix.Tasks.Rlm.Diagnostics do
  @moduledoc """
  Prints a live snapshot of active chat sessions and run trees.
  """

  use Mix.Task

  @shortdoc "Print live runtime diagnostics"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    snapshot = RlmMinimalEx.Diagnostics.snapshot()

    IO.puts("RlmMinimalEx diagnostics")
    IO.puts("")
    IO.puts("Active chats: #{length(snapshot.chats)}")
    Enum.each(snapshot.chats, &print_chat/1)

    IO.puts("")
    IO.puts("Active runs: #{length(snapshot.runs)}")
    Enum.each(snapshot.runs, &print_run/1)
  end

  defp print_chat(%{process: process, status: status}) do
    IO.puts("- chat #{inspect(process[:pid])}")
    IO.puts("  process: #{format_process(process)}")
    IO.puts("  status: #{inspect(status, pretty: true)}")
  end

  defp print_run(run) do
    IO.puts("- run supervisor #{inspect(run.supervisor[:pid])}")
    IO.puts("  session: #{format_process(run.session)}")
    IO.puts("  session_status: #{inspect(run.session_status, pretty: true)}")
    IO.puts("  environment: #{format_process(run.environment)}")
    IO.puts("  environment_status: #{inspect(run.environment_status, pretty: true)}")
    IO.puts("  task_supervisor: #{format_process(run.task_supervisor)}")
  end

  defp format_process(nil), do: "not running"

  defp format_process(process) do
    inspect(%{
      pid: process[:pid],
      status: process[:status],
      message_queue_len: process[:message_queue_len],
      memory: process[:memory],
      reductions: process[:reductions],
      current_function: process[:current_function]
    })
  end
end
