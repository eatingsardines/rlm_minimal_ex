defmodule RlmMinimalEx.Diagnostics do
  @moduledoc """
  Runtime diagnostics helpers for live chat sessions and runs.

  These helpers surface BEAM-friendly process information without dumping the
  full externalized context or provider payloads.
  """

  alias RlmMinimalEx.{ChatSession, Environment, RunSupervisor, Session}

  @process_info_keys [
    :registered_name,
    :status,
    :message_queue_len,
    :memory,
    :reductions,
    :current_function,
    :initial_call
  ]

  @doc """
  Returns a snapshot of all active runs and chat sessions.
  """
  def snapshot do
    %{
      runs: run_snapshots(),
      chats: chat_snapshots()
    }
  end

  @doc """
  Returns snapshots for all active run supervisors.
  """
  def run_snapshots do
    RlmMinimalEx.RunsSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, sup_pid, :supervisor, _modules} -> run_snapshot(sup_pid) end)
  end

  @doc """
  Returns snapshots for all active chat sessions.
  """
  def chat_snapshots do
    RlmMinimalEx.ChatSessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, :worker, _modules} -> chat_snapshot(pid) end)
  end

  @doc """
  Returns a snapshot for one run supervisor tree.
  """
  def run_snapshot(sup_pid) do
    session_pid = RunSupervisor.session(sup_pid)
    env_pid = RunSupervisor.environment(sup_pid)
    task_sup_pid = RunSupervisor.task_supervisor(sup_pid)

    %{
      supervisor: process_snapshot(sup_pid),
      session: process_snapshot(session_pid),
      session_status: safe_status(Session, session_pid),
      environment: process_snapshot(env_pid),
      environment_status: safe_status(Environment, env_pid),
      task_supervisor: process_snapshot(task_sup_pid)
    }
  end

  @doc """
  Returns a snapshot for one chat session process.
  """
  def chat_snapshot(pid) do
    %{
      process: process_snapshot(pid),
      status: safe_status(ChatSession, pid)
    }
  end

  @doc """
  Returns a compact process snapshot for the given pid.
  """
  def process_snapshot(nil), do: nil

  def process_snapshot(pid) when is_pid(pid) do
    case Process.info(pid, @process_info_keys) do
      nil ->
        nil

      info ->
        info
        |> Map.new()
        |> Map.put(:pid, pid)
    end
  end

  defp safe_status(_module, nil), do: nil

  defp safe_status(module, pid) do
    module.status(pid)
  catch
    :exit, _reason -> nil
  end
end
