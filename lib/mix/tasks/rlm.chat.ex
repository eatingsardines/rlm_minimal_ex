defmodule Mix.Tasks.Rlm.Chat do
  use Mix.Task

  alias RlmMinimalEx.Env

  @shortdoc "Starts the interactive RlmMinimalEx terminal interface"

  @moduledoc """
  Starts an interactive chat over one externalized context.

  ## Usage

      mix rlm.chat
      mix rlm.chat --file path/to/context.txt
      mix rlm.chat path/to/context.txt
      mix rlm.chat --model gpt-5.4-nano

  ## Behavior

    * one chat stays open until you choose Start over or Exit
    * follow-up questions reuse the same context and recent answers
    * paste mode ends with `/done` on its own line
    * pressing Ctrl+D during paste ends the current session
    * the default mode is read-only; scratchpad notes still work, but regular writes require `--workspace`

  ## Options

    * `--file` - preload context from a file path
    * `--model` - override the model for this chat
    * `--workspace` - allow regular environment writes during runs
    * `--max-turns` - override the default max turn count
    * `--help` - print this help text
  """

  @switches [
    file: :string,
    model: :string,
    workspace: :boolean,
    max_turns: :integer,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: @switches)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      Env.load_dotenv()
      Mix.Task.run("app.start")

      cli_module = Application.get_env(:rlm_minimal_ex, :cli_module, RlmMinimalEx.CLI)

      cli_opts =
        []
        |> maybe_put(:file, opts[:file] || List.first(rest))
        |> maybe_put(:run_opts, build_run_opts(opts))

      cli_module.start(cli_opts)
    end
  end

  defp build_run_opts(opts) do
    []
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:lane, if(opts[:workspace], do: :workspace))
    |> maybe_put(:max_turns, opts[:max_turns])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
