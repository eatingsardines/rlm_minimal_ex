defmodule RlmMinimalEx do
  @moduledoc """
  Minimal BEAM-native runtime for recursive LLM work.

  `run/3` starts a supervised runtime pair:

  - `RlmMinimalEx.Environment`, which owns externalized state for the run
  - `RlmMinimalEx.Session`, which owns the model turn loop and orchestration

  The model does not receive the full `context` in its first prompt. Context is
  stored in the environment and becomes visible through typed tools such as
  `read_var` and `search_context`.
  """

  alias RlmMinimalEx.Trajectory.Run

  @type run_opts :: [
          model: String.t(),
          model_fn: (String.t(), list(), keyword() -> RlmMinimalEx.Model.response()),
          lane: :read_only | :workspace,
          max_turns: pos_integer(),
          system_prompt: String.t(),
          context_source: {:env_var, pid(), String.t()}
        ]

  @spec run(term(), String.t(), run_opts()) ::
          {:ok, String.t(), Run.t()} | {:error, term(), Run.t()}
  @doc """
  Runs a single session against `query` with `context` stored in the environment.
  """
  def run(context, query, opts \\ []) do
    run_opts = [
      context: context,
      query: query,
      model: opts[:model],
      model_fn: opts[:model_fn],
      lane: Keyword.get(opts, :lane, :read_only),
      max_turns: Keyword.get(opts, :max_turns, 8),
      system_prompt: opts[:system_prompt],
      context_source: opts[:context_source]
    ]

    case DynamicSupervisor.start_child(
           RlmMinimalEx.RunsSupervisor,
           {RlmMinimalEx.RunSupervisor, run_opts}
         ) do
      {:ok, sup_pid} ->
        session_pid = RlmMinimalEx.RunSupervisor.session(sup_pid)

        try do
          RlmMinimalEx.Session.run(session_pid, query)
        after
          DynamicSupervisor.terminate_child(RlmMinimalEx.RunsSupervisor, sup_pid)
        end

      {:error, reason} ->
        {:error, reason, Run.new(query) |> Run.fail()}
    end
  end

  @spec run!(term(), String.t(), run_opts()) :: String.t()
  @doc """
  Same as `run/3`, but returns only the answer string and raises on failure.
  """
  def run!(context, query, opts \\ []) do
    case run(context, query, opts) do
      {:ok, answer, _run} -> answer
      {:error, reason, _run} -> raise "RlmMinimalEx.run! failed: #{inspect(reason)}"
    end
  end
end
