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
    env_pid = resolve_env(opts)

    state = %__MODULE__{
      env_pid: env_pid,
      model_name:
        opts[:model] ||
          Application.get_env(:rlm_minimal_ex, :default_model) ||
          System.get_env("RLM_MINIMAL_EX_MODEL") ||
          "gpt-4o",
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
    answer = extract_last_assistant_content(state.messages)
    run = Run.complete(state.run, answer)
    GenServer.reply(state.reply_to, {:ok, answer, run})
    {:noreply, %{state | run: run}}
  end

  @impl true
  def handle_info({:do_turn, turn}, state) do
    tools = Actions.to_tool_definitions(state.lane)
    turn_start = System.monotonic_time(:millisecond)

    case state.model_fn.(state.model_name, state.messages, tools: tools) do
      {:ok, :text, content, model_call} ->
        step = %Step{
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

        step = %Step{
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
        run = Run.add_step(state.run, step)

        send(self(), {:do_turn, turn + 1})
        {:noreply, %{state | messages: messages, run: run}}

      {:error, reason} ->
        run = Run.fail(state.run)
        GenServer.reply(state.reply_to, {:error, reason, run})
        {:noreply, %{state | run: run}}
    end
  end

  defp resolve_env(opts) do
    case opts[:env_pid] do
      pid when is_pid(pid) ->
        pid

      nil ->
        case opts[:run_id] do
          nil ->
            raise "Session requires either :env_pid or :run_id"

          run_id ->
            case Registry.lookup(RlmMinimalEx.Registry, {:env, run_id}) do
              [{pid, _}] -> pid
              [] -> raise "Environment not found for run_id #{inspect(run_id)}"
            end
        end
    end
  end

  defp execute_tool_calls(calls, state) do
    Enum.map_reduce(calls, [], fn call, msgs ->
      action_name = safe_to_atom(call.name)
      action_start = System.monotonic_time(:millisecond)

      {result, executor} = dispatch_action(action_name, call.arguments, state)
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

  defp dispatch_action(:delegate_subtask, params, state) do
    {do_delegate(params, state), :session}
  end

  defp dispatch_action(action_name, params, state) do
    result = Environment.execute(state.env_pid, action_name, params)
    {result, :environment}
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

    worker_fn = fn ->
      # Delegated workers are one-shot tasks for now, not long-lived processes.
      worker_prompt = """
      You are a focused worker agent. Answer the following task concisely and accurately.
      If context is provided, use it to inform your answer.

      Context:
      #{preview_context(context)}

      Task: #{task}
      """

      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant. Answer concisely."},
        %{"role" => "user", "content" => worker_prompt}
      ]

      case state.model_fn.(state.model_name, messages, []) do
        {:ok, :text, content, _model_call} -> {:ok, content}
        {:ok, :tool_calls, _calls, _mc} -> {:ok, "(Worker produced tool calls, not text)"}
        {:error, reason} -> {:error, "Delegation failed: #{inspect(reason)}"}
      end
    end

    task_ref = Task.Supervisor.async_nolink(RlmMinimalEx.TaskSupervisor, worker_fn)

    case Task.yield(task_ref, :timer.minutes(2)) || Task.shutdown(task_ref) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "Worker crashed: #{inspect(reason)}"}
      nil -> {:error, "Worker timed out"}
    end
  end

  defp safe_to_atom(name) when is_atom(name), do: name

  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp preview_context(nil), do: "(no context)"

  defp preview_context(ctx) when is_binary(ctx) and byte_size(ctx) > 4_000 do
    String.slice(ctx, 0, 4_000) <> "\n... (truncated)"
  end

  defp preview_context(ctx) when is_binary(ctx), do: ctx
  defp preview_context(ctx), do: inspect(ctx, limit: 50, printable_limit: 4_000)

  defp extract_last_assistant_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => c} when is_binary(c) -> c
      _ -> nil
    end) || "No answer produced"
  end

  defp default_system_prompt do
    """
    You are a coordinator agent in the RlmMinimalEx runtime. You have access to tools \
    that let you read and search an externalized context, store intermediate results, \
    and delegate subtasks to worker agents.

    Strategy:
    1. Start by reading or searching the context to understand what you're working with.
    2. If the task is complex, break it into subtasks and delegate them.
    3. Use search_context to find relevant information before answering.
    4. When you have enough information, respond with your final answer as plain text.

    Be precise. Be concise. Use the tools when they help, but don't over-use them.\
    """
  end
end
