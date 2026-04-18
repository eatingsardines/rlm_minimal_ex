defmodule RlmMinimalEx.RunSupervisor do
  @moduledoc """
  Per-run supervisor for the core runtime tree.

  Each run starts:

  - one `RlmMinimalEx.Environment`
  - one per-run `Task.Supervisor`
  - one `RlmMinimalEx.Session`

  The strategy is `:one_for_all`, so the run behaves as a unit.
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

  @doc """
  Finds the environment child pid for a run supervisor.
  """
  def environment(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {RlmMinimalEx.Environment, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  @doc """
  Finds the per-run task supervisor pid for a run supervisor.
  """
  def task_supervisor(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{Task.Supervisor, _run_id}, pid, _type, [Task.Supervisor]} -> pid
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
      system_prompt: opts[:system_prompt],
      conversation_history: opts[:conversation_history] || [],
      delegate_depth: opts[:delegate_depth] || 0,
      delegate_count: opts[:delegate_count] || 0,
      max_delegate_depth: opts[:max_delegate_depth],
      max_delegate_count: opts[:max_delegate_count]
    ]

    children = [
      %{
        id: RlmMinimalEx.Environment,
        start: {RlmMinimalEx.Environment, :start_link, [env_opts]}
      },
      %{
        id: {Task.Supervisor, run_id},
        start:
          {Task.Supervisor, :start_link,
           [[name: {:via, Registry, {RlmMinimalEx.Registry, {:task_sup, run_id}}}]]}
      },
      %{
        id: RlmMinimalEx.Session,
        start: {RlmMinimalEx.Session, :start_link, [session_opts]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
