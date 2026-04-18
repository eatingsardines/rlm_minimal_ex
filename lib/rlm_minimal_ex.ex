defmodule RlmMinimalEx do
  @moduledoc """
  Minimal BEAM-native runtime for recursive LLM work.

  `run/3` starts a supervised runtime tree:

  - `RlmMinimalEx.Environment`, which owns externalized state for the run
  - a per-run `Task.Supervisor`, which owns async turn and worker tasks
  - `RlmMinimalEx.Session`, which owns the model turn loop and orchestration

  The model does not receive the full `context` in its first prompt. Context is
  stored in the environment and becomes visible through typed tools such as
  `read_var` and `search_context`.
  """

  alias RlmMinimalEx.{RuntimeTelemetry, Session}
  alias RlmMinimalEx.Trajectory.Run

  @type conversation_message :: %{role: :user | :assistant, content: String.t()}

  @type run_opts :: [
          model: String.t(),
          model_fn: (String.t(), list(), keyword() -> RlmMinimalEx.Model.response()),
          lane: :read_only | :workspace,
          max_turns: pos_integer(),
          system_prompt: String.t(),
          context_source: {:env_var, pid(), String.t()},
          conversation_history: [conversation_message()],
          delegate_depth: non_neg_integer(),
          delegate_count: non_neg_integer(),
          max_delegate_depth: non_neg_integer(),
          max_delegate_count: non_neg_integer()
        ]

  @spec run(term(), String.t(), run_opts()) ::
          {:ok, String.t(), Run.t()} | {:error, term(), Run.t()}
  @doc """
  Runs a single session against `query` with `context` stored in the environment.

  `:conversation_history` can be passed to provide prior user/assistant turns for
  conversational continuity across multiple runs. Large source material should
  still remain externalized in the environment rather than copied into the
  conversation history.
  """
  def run(context, query, opts \\ []) do
    run_start = System.monotonic_time(:millisecond)

    run_opts = [
      context: context,
      query: query,
      model: opts[:model],
      model_fn: opts[:model_fn],
      lane: Keyword.get(opts, :lane, :read_only),
      max_turns: Keyword.get(opts, :max_turns, 8),
      system_prompt: opts[:system_prompt],
      context_source: opts[:context_source],
      conversation_history: opts[:conversation_history] || [],
      delegate_depth: Keyword.get(opts, :delegate_depth, 0),
      delegate_count: Keyword.get(opts, :delegate_count, 0),
      max_delegate_depth:
        Keyword.get(opts, :max_delegate_depth, Session.default_max_delegate_depth()),
      max_delegate_count:
        Keyword.get(opts, :max_delegate_count, Session.default_max_delegate_count())
    ]

    RuntimeTelemetry.execute(
      [:run, :start],
      %{system_time: System.system_time()},
      %{
        lane: run_opts[:lane],
        max_turns: run_opts[:max_turns],
        delegate_depth: run_opts[:delegate_depth],
        delegate_count: run_opts[:delegate_count],
        max_delegate_depth: run_opts[:max_delegate_depth],
        max_delegate_count: run_opts[:max_delegate_count],
        conversation_history_count: length(run_opts[:conversation_history]),
        context_loaded?: not is_nil(context) or not is_nil(run_opts[:context_source])
      }
    )

    case DynamicSupervisor.start_child(
           RlmMinimalEx.RunsSupervisor,
           {RlmMinimalEx.RunSupervisor, run_opts}
         ) do
      {:ok, sup_pid} ->
        session_pid = RlmMinimalEx.RunSupervisor.session(sup_pid)

        result =
          try do
            RlmMinimalEx.Session.run(session_pid, query)
          after
            DynamicSupervisor.terminate_child(RlmMinimalEx.RunsSupervisor, sup_pid)
          end

        emit_run_stop(result, run_start)
        result

      {:error, reason} ->
        result = {:error, reason, Run.new(query) |> Run.fail()}
        emit_run_stop(result, run_start)
        result
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

  defp emit_run_stop(result, run_start) do
    metadata =
      case result do
        {:ok, _answer, run} ->
          %{status: run.status, total_tokens: run.total_tokens, step_count: length(run.steps)}

        {:error, reason, run} ->
          %{
            status: run.status,
            reason: inspect(reason),
            total_tokens: run.total_tokens,
            step_count: length(run.steps)
          }
      end

    RuntimeTelemetry.execute(
      [:run, :stop],
      %{duration_ms: System.monotonic_time(:millisecond) - run_start},
      metadata
    )
  end
end
