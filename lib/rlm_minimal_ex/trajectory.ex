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
      :executor,
      :duration_ms,
      :timestamp
    ]

    @type t :: %__MODULE__{
            name: atom() | String.t(),
            params: map(),
            result: term(),
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
      :turn,
      :model_call,
      :actions,
      :duration_ms
    ]

    @type t :: %__MODULE__{
            turn: non_neg_integer(),
            model_call: ModelCall.t(),
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
            steps: [Step.t()],
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
        steps: [],
        started_at: DateTime.utc_now(),
        completed_at: nil,
        total_tokens: 0
      }
    end

    @doc """
    Appends a step and accumulates any reported token usage.
    """
    def add_step(%__MODULE__{} = run, %Step{} = step) do
      tokens =
        (step.model_call &&
           (step.model_call.input_tokens || 0) + (step.model_call.output_tokens || 0)) || 0

      %{run | steps: run.steps ++ [step], total_tokens: run.total_tokens + tokens}
    end

    @doc """
    Marks the run as completed with the final `answer`.
    """
    def complete(%__MODULE__{} = run, answer) do
      %{run | answer: answer, status: :completed, completed_at: DateTime.utc_now()}
    end

    @doc """
    Marks the run as failed.
    """
    def fail(%__MODULE__{} = run) do
      %{run | status: :failed, completed_at: DateTime.utc_now()}
    end
  end
end
