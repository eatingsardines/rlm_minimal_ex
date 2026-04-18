defmodule RlmMinimalEx.RunSupervisor do
  @moduledoc """
  Per-run supervisor for the core runtime pair.

  Each run starts:

  - one `RlmMinimalEx.Environment`
  - one `RlmMinimalEx.Session`

  The strategy is `:one_for_all`, so the pair behaves as a unit.
  """
  use Supervisor

  @doc """
  Starts a per-run supervisor.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Finds the session child pid for a run supervisor.
  """
  def session(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {RlmMinimalEx.Session, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  @impl true
  def init(opts) do
    run_id = make_ref()

    env_opts = [
      run_id: run_id,
      context: opts[:context],
      context_source: opts[:context_source],
      query: opts[:query],
      lane: opts[:lane] || :read_only
    ]

    session_opts = [
      run_id: run_id,
      model: opts[:model],
      model_fn: opts[:model_fn],
      lane: opts[:lane] || :read_only,
      max_turns: opts[:max_turns] || 8,
      system_prompt: opts[:system_prompt]
    ]

    children = [
      %{
        id: RlmMinimalEx.Environment,
        start: {RlmMinimalEx.Environment, :start_link, [env_opts]}
      },
      %{
        id: RlmMinimalEx.Session,
        start: {RlmMinimalEx.Session, :start_link, [session_opts]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
