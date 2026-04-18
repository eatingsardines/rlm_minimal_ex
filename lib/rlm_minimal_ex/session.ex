defmodule RlmMinimalEx.Session do
  @moduledoc """
  Owns the model turn loop and orchestration for a single run.

  The initial model turn sees:

  - the system prompt
  - the user's query
  - the available tool definitions

  It does not receive the full run context directly. Context lives in
  `RlmMinimalEx.Environment` and becomes visible through tools such as
  `read_var` and `search_context`.
  """
  use GenServer

  alias RlmMinimalEx.{Actions, Environment, Trajectory}
  alias Trajectory.{Action, Run, Step}

  defstruct [
    :env_pid,
    :model_name,
    :model_fn,
    :query,
    :lane,
    :max_turns,
    :messages,
    :run,
    :reply_to,
    :system_prompt
  ]

  @doc """
  Starts a session process for a run.
  """
  def start_link(opts) do
    gen_opts =
      case opts[:run_id] do
        nil -> []
        run_id -> [name: {:via, Registry, {RlmMinimalEx.Registry, {:session, run_id}}}]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Runs the session against `query` and returns the final answer and trajectory.
  """
  def run(pid, query) do
    GenServer.call(pid, {:run, query}, :timer.minutes(5))
  end

  @impl true
  def init(opts) do
    RlmMinimalEx.Env.load_dotenv()
    env_pid = resolve_env(opts)

    state = %__MODULE__{
      env_pid: env_pid,
      model_name:
        opts[:model] ||
          System.get_env("RLM_MINIMAL_EX_MODEL") ||
          Application.get_env(:rlm_minimal_ex, :default_model, "gpt-5.4-nano"),
      model_fn: opts[:model_fn] || (&RlmMinimalEx.Model.chat/3),
      lane: opts[:lane] || :read_only,
      max_turns: opts[:max_turns] || 8,
      messages: [],
      run: nil,
      reply_to: nil,
      system_prompt: opts[:system_prompt] || default_system_prompt()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:run, query}, from, state) do
    run = Run.new(query)

    # The initial prompt contains only the system prompt and query. The model
    # must use tools to inspect the externalized context stored in the environment.
    messages = [
      %{"role" => "system", "content" => state.system_prompt},
      %{"role" => "user", "content" => query}
    ]

    state = %{state | query: query, messages: messages, run: run, reply_to: from}
    send(self(), {:do_turn, 0})
    {:noreply, state}
  end

  @impl true
  def handle_info({:do_turn, turn}, state) when turn >= state.max_turns do
    run = Run.timeout(state.run)
    GenServer.reply(state.reply_to, {:error, :max_turns_exceeded, run})
    {:noreply, %{state | run: run}}
  end

  @impl true
  def handle_info({:do_turn, turn}, state) do
    tools = Actions.to_tool_definitions(state.lane)
    turn_start = System.monotonic_time(:millisecond)

    case state.model_fn.(state.model_name, state.messages, tools: tools) do
      {:ok, :text, content, model_call} ->
        step = %Step{
          path: [turn],
          turn: turn,
          model_call: model_call,
          actions: [],
          duration_ms: System.monotonic_time(:millisecond) - turn_start
        }

        run = state.run |> Run.add_step(step) |> Run.complete(content)
        GenServer.reply(state.reply_to, {:ok, content, run})
        {:noreply, %{state | run: run}}

      {:ok, :tool_calls, calls, model_call} ->
        {action_entries, tool_messages} = execute_tool_calls(calls, state)
        child_runs = child_runs(action_entries)

        step = %Step{
          path: [turn],
          turn: turn,
          model_call: model_call,
          actions: action_entries,
          duration_ms: System.monotonic_time(:millisecond) - turn_start
        }

        # Recreate the assistant tool-call message so the next provider turn sees
        # the same tool invocation history the runtime just executed.
        assistant_msg = %{
          "role" => "assistant",
          "tool_calls" =>
            Enum.map(calls, fn c ->
              %{
                "id" => c.id,
                "type" => "function",
                "function" => %{
                  "name" => c.name,
                  "arguments" => Jason.encode!(c.arguments)
                }
              }
            end)
        }

        messages = state.messages ++ [assistant_msg | tool_messages]
        run = Run.add_step(state.run, step, child_runs)

        send(self(), {:do_turn, turn + 1})
        {:noreply, %{state | messages: messages, run: run}}

      {:error, reason} ->
        run = Run.fail(state.run)
        GenServer.reply(state.reply_to, {:error, reason, run})
        {:noreply, %{state | run: run}}
    end
  end

  defp resolve_env(opts) do
    opts[:env_pid] || resolve_env_from_run_id(opts[:run_id])
  end

  defp resolve_env_from_run_id(nil) do
    raise "Session requires either :env_pid or :run_id"
  end

  defp resolve_env_from_run_id(run_id) do
    case Registry.lookup(RlmMinimalEx.Registry, {:env, run_id}) do
      [{pid, _}] -> pid
      [] -> raise "Environment not found for run_id #{inspect(run_id)}"
    end
  end

  defp execute_tool_calls(calls, state) do
    Enum.map_reduce(calls, [], fn call, msgs ->
      action_name = safe_to_atom(call.name)
      action_start = System.monotonic_time(:millisecond)

      {result, executor, child_run} = dispatch_action(action_name, call.arguments, state)
      duration = System.monotonic_time(:millisecond) - action_start

      content =
        case result do
          {:ok, text} -> text
          {:error, text} -> "ERROR: #{text}"
        end

      action_entry = %Action{
        name: action_name,
        params: call.arguments,
        result: content,
        child_run: child_run,
        executor: executor,
        duration_ms: duration,
        timestamp: DateTime.utc_now()
      }

      tool_msg = %{
        "role" => "tool",
        "tool_call_id" => call.id,
        "content" => content
      }

      {action_entry, msgs ++ [tool_msg]}
    end)
  end

  defp child_runs(actions) do
    Enum.flat_map(actions, fn
      %Action{child_run: nil} -> []
      %Action{child_run: child_run} -> [child_run]
    end)
  end

  defp dispatch_action(:delegate_subtask, params, state) do
    {result, child_run} = do_delegate(params, state)
    {result, :session, child_run}
  end

  defp dispatch_action(action_name, params, state) do
    result = Environment.execute(state.env_pid, action_name, params)
    {result, :environment, nil}
  end

  defp do_delegate(params, state) do
    task = params["task"]
    context_var = params["context_var"]

    context =
      if context_var do
        Environment.get_var(state.env_pid, context_var)
      else
        Environment.get_var(state.env_pid, "context")
      end

    worker_opts = [
      model: state.model_name,
      model_fn: state.model_fn,
      lane: state.lane,
      max_turns: state.max_turns,
      system_prompt: worker_system_prompt()
    ]

    worker_fn = fn ->
      case RlmMinimalEx.run(context, task, worker_opts) do
        {:ok, answer, run} -> {{:ok, answer}, run}
        {:error, reason, run} -> {{:error, "Delegation failed: #{inspect(reason)}"}, run}
        {:error, reason} -> {{:error, "Delegation failed: #{inspect(reason)}"}, nil}
      end
    end

    task_ref = Task.Supervisor.async_nolink(RlmMinimalEx.TaskSupervisor, worker_fn)

    case Task.yield(task_ref, :timer.minutes(2)) || Task.shutdown(task_ref) do
      {:ok, {result, child_run}} -> {result, child_run}
      {:exit, reason} -> {{:error, "Worker crashed: #{inspect(reason)}"}, nil}
      nil -> {{:error, "Worker timed out"}, nil}
    end
  end

  defp safe_to_atom(name) when is_atom(name), do: name

  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp default_system_prompt do
    """
    You are a coordinator agent in the RlmMinimalEx runtime. You have access to tools \
    that let you inspect an externalized context, store intermediate results in the \
    scratchpad namespace, and delegate subtasks to worker agents.

    Strategy:
    1. Start by inspecting the externalized context before answering. Prefer tools such as \
    search_context, read_var, read_text_range, and read_lines to gather evidence.
    2. If you discover a useful intermediate result, store it with write_scratchpad so you can \
    reuse it in later turns.
    3. Use slice_text to create focused chunks when a smaller section of the context is easier \
    to reason about than the whole input.
    4. If the task is complex, break it into subtasks and delegate them only after inspecting \
    the relevant context yourself.
    5. Do not answer until you have inspected the context with at least one read/search tool \
    unless the user explicitly gave you the answer in the query itself.
    6. When you have enough information, respond with your final answer as plain text.

    Be precise. Be concise. Use the tools when they help, but don't over-use them.\
    """
  end

  defp worker_system_prompt do
    """
    You are a focused worker agent in the RlmMinimalEx runtime. You are solving a scoped task \
    against a scoped externalized context. Use the available tools to inspect the context before \
    answering.

    Strategy:
    1. Inspect the scoped context with read/search tools before answering.
    2. Use write_scratchpad if intermediate notes help.
    3. Use slice_text when a smaller chunk is easier to reason about.
    4. Delegate again only if absolutely necessary.
    5. Return your final answer as plain text once you have enough evidence.

    Be concise, accurate, and tool-using when it helps.\
    """
  end
end
