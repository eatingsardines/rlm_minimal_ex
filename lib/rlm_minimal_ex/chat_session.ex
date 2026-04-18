defmodule RlmMinimalEx.ChatSession do
  @moduledoc """
  Owns cross-turn conversational state for an interactive chat session.

  A chat session sits above the existing runtime:

  - `RlmMinimalEx.ChatSession` stores conversation history across turns
  - `RlmMinimalEx.ChatSession` retains a bounded recent run history
  - `RlmMinimalEx.run/3` still executes exactly one runtime run per query

  This keeps per-run semantics intact while making follow-up questions such as
  `deeper` or `expand that` work in the CLI.
  """

  use GenServer

  alias RlmMinimalEx.Trajectory.Run

  @typedoc """
  Provider-agnostic conversation message stored across chat turns.
  """
  @type transcript_entry :: %{role: :user | :assistant, content: String.t()}

  @typedoc """
  Function used to execute one runtime query.
  """
  @type run_fun ::
          (term(), String.t(), keyword() ->
             {:ok, String.t(), Run.t()} | {:error, term()} | {:error, term(), Run.t()})

  defstruct [
    :context,
    :in_flight,
    :last_answer,
    :run_fun,
    dropped_run_count: 0,
    transcript: [],
    runs: [],
    run_opts: [],
    max_recent_turns: 8,
    max_runs: 20
  ]

  @type state :: %__MODULE__{
          context: term(),
          in_flight: %{task: Task.t(), from: GenServer.from(), query: String.t()} | nil,
          last_answer: String.t() | nil,
          run_fun: run_fun(),
          dropped_run_count: non_neg_integer(),
          transcript: [transcript_entry()],
          runs: [Run.t()],
          run_opts: keyword(),
          max_recent_turns: pos_integer(),
          max_runs: pos_integer()
        }

  @doc """
  Starts a chat session under `RlmMinimalEx.ChatSessionSupervisor`.

  Supported options include `:max_recent_turns` for transcript retention and
  `:max_runs` for bounded recent run retention.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts \\ []) do
    DynamicSupervisor.start_child(RlmMinimalEx.ChatSessionSupervisor, {__MODULE__, opts})
  end

  @doc """
  Starts a standalone chat session process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Runs one conversational turn and records the resulting transcript state.
  """
  @spec ask(pid(), String.t()) :: {:ok, String.t(), Run.t()} | {:error, term(), Run.t()}
  def ask(pid, query) do
    GenServer.call(pid, {:ask, query}, :timer.minutes(5))
  end

  @doc """
  Returns a compact status snapshot for the live chat session.
  """
  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Returns the most recent run for the chat session, if one exists.
  """
  @spec last_run(pid()) :: Run.t() | nil
  def last_run(pid) do
    GenServer.call(pid, :last_run)
  end

  @doc """
  Returns the retained recent runs for the chat session in chronological order.
  """
  @spec runs(pid()) :: [Run.t()]
  def runs(pid) do
    GenServer.call(pid, :runs)
  end

  @doc """
  Clears conversation history and prior runs while keeping the current context.
  """
  @spec reset(pid()) :: :ok
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  @doc """
  Replaces the current context and clears any prior conversation state.
  """
  @spec update_context(pid(), term()) :: :ok
  def update_context(pid, context) do
    GenServer.call(pid, {:update_context, context})
  end

  @doc """
  Stops the chat session.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, make_ref()),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      context: Keyword.get(opts, :context),
      in_flight: nil,
      last_answer: nil,
      run_fun: Keyword.get(opts, :run_fun, &RlmMinimalEx.run/3),
      dropped_run_count: 0,
      transcript: [],
      runs: [],
      run_opts: Keyword.get(opts, :run_opts, []),
      max_recent_turns: Keyword.get(opts, :max_recent_turns, 8),
      max_runs: Keyword.get(opts, :max_runs, 20)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ask, query}, _from, %{in_flight: %{}} = state) do
    {:reply, {:error, :session_busy, Run.new(query) |> Run.fail()}, state}
  end

  @impl true
  def handle_call({:ask, query}, from, %{in_flight: nil} = state) do
    context = state.context
    run_fun = state.run_fun
    run_opts = build_run_opts(state)

    task =
      Task.Supervisor.async_nolink(RlmMinimalEx.ChatTaskSupervisor, fn ->
        run_fun.(context, query, run_opts)
      end)

    {:noreply, %{state | in_flight: %{task: task, from: from, query: query}}}
  end

  @impl true
  def handle_call(:last_run, _from, state) do
    {:reply, List.first(state.runs), state}
  end

  @impl true
  def handle_call(:runs, _from, state) do
    {:reply, Enum.reverse(state.runs), state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, chat_status(state), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, reset_conversation(state)}
  end

  @impl true
  def handle_call({:update_context, context}, _from, state) do
    next_state = state |> reset_conversation() |> Map.put(:context, context)
    {:reply, :ok, next_state}
  end

  @impl true
  def handle_info({ref, result}, %{in_flight: %{task: %Task{ref: ref}} = in_flight} = state) do
    Process.demonitor(ref, [:flush])

    case normalize_run_result(in_flight.query, result) do
      {:ok, answer, run} ->
        next_state =
          state
          |> record_success(in_flight.query, answer, run)
          |> clear_in_flight()

        GenServer.reply(in_flight.from, {:ok, answer, run})
        {:noreply, next_state}

      {:error, reason, run} ->
        next_state =
          state
          |> record_run(run)
          |> clear_in_flight()

        GenServer.reply(in_flight.from, {:error, reason, run})
        {:noreply, next_state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: %{task: %Task{ref: ref}, from: from, query: query}} = state
      ) do
    run = Run.new(query) |> Run.fail()

    next_state =
      state
      |> record_run(run)
      |> clear_in_flight()

    GenServer.reply(from, {:error, {:task_exit, reason}, run})
    {:noreply, next_state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    shutdown_in_flight_task(state.in_flight)
    :ok
  end

  defp build_run_opts(state) do
    case conversation_history(state) do
      [] -> state.run_opts
      history -> Keyword.put(state.run_opts, :conversation_history, history)
    end
  end

  defp conversation_history(state) do
    Enum.reverse(state.transcript)
  end

  defp record_success(state, query, answer, run) do
    max_messages = state.max_recent_turns * 2

    transcript =
      [
        %{role: :assistant, content: answer},
        %{role: :user, content: query}
        | state.transcript
      ]
      |> Enum.take(max_messages)

    state
    |> Map.put(:transcript, transcript)
    |> Map.put(:last_answer, answer)
    |> record_run(run)
  end

  defp reset_conversation(state) do
    %{state | transcript: [], runs: [], last_answer: nil, dropped_run_count: 0}
  end

  defp clear_in_flight(state) do
    %{state | in_flight: nil}
  end

  defp record_run(state, run) do
    runs = [run | state.runs]
    retained_runs = Enum.take(runs, state.max_runs)
    dropped_count = max(length(runs) - length(retained_runs), 0)

    %{
      state
      | runs: retained_runs,
        dropped_run_count: state.dropped_run_count + dropped_count
    }
  end

  defp chat_status(state) do
    %{
      busy?: state.in_flight != nil,
      in_flight_query: state.in_flight && state.in_flight.query,
      transcript_message_count: length(state.transcript),
      max_runs: state.max_runs,
      run_count: length(state.runs),
      dropped_run_count: state.dropped_run_count,
      context_loaded?: not is_nil(state.context),
      last_answer_preview: preview(state.last_answer)
    }
  end

  defp shutdown_in_flight_task(nil), do: :ok

  defp shutdown_in_flight_task(%{task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp preview(nil), do: nil

  defp preview(text) when is_binary(text) do
    if String.length(text) > 120 do
      String.slice(text, 0, 120) <> "..."
    else
      text
    end
  end

  defp normalize_run_result(query, {:error, reason}) do
    {:error, reason, Run.new(query) |> Run.fail()}
  end

  defp normalize_run_result(_query, result), do: result
end
