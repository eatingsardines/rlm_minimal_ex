defmodule RlmMinimalEx.Trajectory do
  @moduledoc """
  Structured runtime trace types for minimal runs.
  """

  defmodule ModelCall do
    @moduledoc """
    Records one provider-facing model invocation.
    """

    defstruct [
      :model,
      :messages_in,
      :tools_offered,
      :tool_calls_made,
      :response_type,
      :input_tokens,
      :output_tokens,
      :duration_ms
    ]

    @type t :: %__MODULE__{
            model: String.t(),
            messages_in: non_neg_integer(),
            tools_offered: [String.t()],
            tool_calls_made: [String.t() | atom()],
            response_type: :tool_calls | :text,
            input_tokens: non_neg_integer() | nil,
            output_tokens: non_neg_integer() | nil,
            duration_ms: non_neg_integer() | nil
          }
  end

  defmodule Action do
    @moduledoc """
    Records one tool execution inside a turn.
    """

    defstruct [
      :name,
      :params,
      :result,
      :child_run,
      :executor,
      :duration_ms,
      :timestamp
    ]

    @type t :: %__MODULE__{
            name: atom() | String.t(),
            params: map(),
            result: term(),
            child_run: Run.t() | nil,
            executor: :environment | :session,
            duration_ms: non_neg_integer() | nil,
            timestamp: DateTime.t()
          }
  end

  defmodule Step do
    @moduledoc """
    Records one turn of the session loop.
    """

    defstruct [
      :path,
      :turn,
      :model_call,
      :assistant_text,
      :actions,
      :duration_ms
    ]

    @type t :: %__MODULE__{
            path: [non_neg_integer()],
            turn: non_neg_integer(),
            model_call: ModelCall.t(),
            assistant_text: String.t() | nil,
            actions: [Action.t()],
            duration_ms: non_neg_integer() | nil
          }
  end

  defmodule Run do
    @moduledoc """
    Records the outcome and ordered steps for a single run.
    """

    defstruct [
      :id,
      :query,
      :answer,
      :status,
      :root_steps,
      :steps,
      :started_at,
      :completed_at,
      :total_tokens
    ]

    @type t :: %__MODULE__{
            id: reference(),
            query: String.t(),
            answer: String.t() | nil,
            status: :running | :completed | :failed | :timeout,
            root_steps: [Step.t()] | :queue.queue(Step.t()),
            steps: [Step.t()] | :queue.queue(Step.t()),
            started_at: DateTime.t(),
            completed_at: DateTime.t() | nil,
            total_tokens: non_neg_integer()
          }

    @doc """
    Creates a new running trajectory record for `query`.
    """
    def new(query) do
      %__MODULE__{
        id: make_ref(),
        query: query,
        answer: nil,
        status: :running,
        root_steps: :queue.new(),
        steps: :queue.new(),
        started_at: DateTime.utc_now(),
        completed_at: nil,
        total_tokens: 0
      }
    end

    @doc """
    Appends a step and accumulates any reported token usage.
    """
    def add_step(%__MODULE__{} = run, %Step{} = step) do
      add_step(run, step, [])
    end

    @doc """
    Appends a root step and any nested child runs into the flattened execution timeline.
    """
    def add_step(%__MODULE__{} = run, %Step{} = step, child_runs) do
      tokens =
        (step.model_call &&
           (step.model_call.input_tokens || 0) + (step.model_call.output_tokens || 0)) || 0

      nested_steps =
        child_runs
        |> Enum.with_index()
        |> Enum.flat_map(fn {child_run, action_index} ->
          flatten_nested_steps(child_run, [step.turn, action_index])
        end)

      nested_tokens =
        Enum.reduce(child_runs, 0, fn child_run, acc ->
          acc + child_run.total_tokens
        end)

      timeline_steps = [step | nested_steps]

      %{
        run
        | root_steps: :queue.in(step, run.root_steps),
          steps: Enum.reduce(timeline_steps, run.steps, &:queue.in/2),
          total_tokens: run.total_tokens + tokens + nested_tokens
      }
    end

    @doc """
    Marks the run as completed with the final `answer`.
    """
    def complete(%__MODULE__{} = run, answer) do
      run
      |> materialize_step_queues()
      |> Map.merge(%{answer: answer, status: :completed, completed_at: DateTime.utc_now()})
    end

    @doc """
    Marks the run as failed.
    """
    def fail(%__MODULE__{} = run) do
      run
      |> materialize_step_queues()
      |> Map.merge(%{status: :failed, completed_at: DateTime.utc_now()})
    end

    @doc """
    Marks the run as timed out.
    """
    def timeout(%__MODULE__{} = run) do
      run
      |> materialize_step_queues()
      |> Map.merge(%{status: :timeout, completed_at: DateTime.utc_now()})
    end

    @doc """
    Returns only nested delegated steps from the flattened timeline.
    """
    def delegate_steps(%__MODULE__{} = run) do
      run
      |> ordered_steps()
      |> Enum.filter(fn %Step{path: path} -> nested_step_path?(path) end)
    end

    @doc """
    Renders the flattened execution timeline into a readable multi-line string.
    """
    def pretty_timeline(%__MODULE__{} = run) do
      header = "Run status=#{run.status} total_tokens=#{run.total_tokens}"

      lines =
        Enum.map(ordered_steps(run), fn %Step{} = step ->
          indent = String.duplicate("  ", nesting_level(step.path))
          path = Enum.map_join(step.path, ".", &Integer.to_string/1)
          actions = step.actions |> Enum.map_join(", ", &format_action_name/1)
          action_suffix = if actions == "", do: "", else: " actions=[#{actions}]"

          "#{indent}[#{path}] turn=#{step.turn} #{step.model_call.response_type}#{action_suffix}"
        end)

      Enum.join([header | lines], "\n")
    end

    @doc """
    Renders a detailed execution timeline with tool params, results, and assistant text.
    """
    def detailed_timeline(%__MODULE__{} = run) do
      header = [
        "Run status=#{run.status} total_tokens=#{run.total_tokens}",
        "Query: #{run.query}"
      ]

      answer_line =
        case run.answer do
          nil -> []
          answer -> ["Answer: #{answer}"]
        end

      lines =
        Enum.flat_map(ordered_steps(run), fn %Step{} = step ->
          indent = String.duplicate("  ", nesting_level(step.path))
          path = Enum.map_join(step.path, ".", &Integer.to_string/1)
          action_names = Enum.map_join(step.actions, ", ", &format_action_name/1)

          step_line =
            "#{indent}[#{path}] turn=#{step.turn} response=#{step.model_call.response_type}" <>
              " model=#{step.model_call.model}" <>
              maybe_suffix(" input_tokens", step.model_call.input_tokens) <>
              maybe_suffix(" output_tokens", step.model_call.output_tokens) <>
              maybe_suffix(" duration_ms", step.duration_ms) <>
              if(action_names == "", do: "", else: " tool_calls=[#{action_names}]")

          action_lines =
            Enum.flat_map(step.actions, fn %Action{} = action ->
              action_indent = indent <> "  "

              [
                "#{action_indent}- action=#{action.name} executor=#{action.executor}" <>
                  maybe_suffix(" duration_ms", action.duration_ms),
                "#{action_indent}  params: #{inspect(action.params, pretty: true)}",
                "#{action_indent}  result:",
                indent_block(to_string(action.result), action_indent <> "    ")
              ]
            end)

          assistant_lines =
            case step.assistant_text do
              nil ->
                []

              text ->
                [
                  indent <> "  assistant:",
                  indent_block(text, indent <> "    ")
                ]
            end

          [step_line | action_lines ++ assistant_lines]
        end)

      Enum.join(header ++ answer_line ++ lines, "\n")
    end

    defp flatten_nested_steps(%__MODULE__{} = run, prefix) do
      Enum.map(ordered_steps(run), fn %Step{} = step ->
        %{step | path: prefix ++ step.path}
      end)
    end

    defp materialize_step_queues(%__MODULE__{} = run) do
      %{run | root_steps: ordered_root_steps(run), steps: ordered_steps(run)}
    end

    defp ordered_root_steps(%__MODULE__{root_steps: root_steps}) when is_list(root_steps),
      do: root_steps

    defp ordered_root_steps(%__MODULE__{root_steps: root_steps}), do: :queue.to_list(root_steps)

    defp ordered_steps(%__MODULE__{steps: steps}) when is_list(steps), do: steps
    defp ordered_steps(%__MODULE__{steps: steps}), do: :queue.to_list(steps)

    defp format_action_name(%Action{name: name}), do: to_string(name)

    defp nesting_level(path), do: div(length(path) - 1, 2)

    defp nested_step_path?(path), do: length(path) > 1

    defp maybe_suffix(_label, nil), do: ""
    defp maybe_suffix(label, value), do: "#{label}=#{value}"

    defp indent_block(text, indent) do
      text
      |> String.split("\n")
      |> Enum.map_join("\n", fn line -> indent <> line end)
    end
  end
end
