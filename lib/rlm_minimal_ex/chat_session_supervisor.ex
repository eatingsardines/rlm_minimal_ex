defmodule RlmMinimalEx.ChatSessionSupervisor do
  @moduledoc """
  Supervises long-lived chat sessions.

  Each `RlmMinimalEx.ChatSession` owns cross-turn conversational state, while
  the existing runtime continues to execute one run per query.
  """
  use DynamicSupervisor

  @doc """
  Starts the chat session supervisor.
  """
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
