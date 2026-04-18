defmodule RlmMinimalEx.Application do
  @moduledoc """
  Top-level OTP application for the minimal runtime.

  Shared services:

  - `RlmMinimalEx.Registry` for per-run process lookup
  - `RlmMinimalEx.ChatSessionSupervisor` for long-lived interactive chat sessions
  - `RlmMinimalEx.TaskSupervisor` for delegated one-shot worker tasks
  - `RlmMinimalEx.RunsSupervisor` for per-run supervision trees
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: RlmMinimalEx.Registry},
      {RlmMinimalEx.ChatSessionSupervisor, []},
      {Task.Supervisor, name: RlmMinimalEx.TaskSupervisor},
      {DynamicSupervisor, name: RlmMinimalEx.RunsSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: RlmMinimalEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
