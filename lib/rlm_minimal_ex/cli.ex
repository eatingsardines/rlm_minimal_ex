defmodule RlmMinimalEx.CLI do
  @moduledoc """
  Public entrypoint for the interactive terminal interface.

  `RlmMinimalEx.CLI` stays intentionally small so the interactive flow can live
  under `RlmMinimalEx.CLI.*` without changing the public module users call from
  the Mix task or tests.
  """

  @doc """
  Starts the interactive CLI session.

  The supported options are the same ones passed in from `mix rlm.chat`, such
  as a preloaded `:file` path or `:run_opts` forwarded to `RlmMinimalEx.run/3`.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []), do: RlmMinimalEx.CLI.Runner.start(opts)
end
