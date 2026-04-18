# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

## Quick Start

```bash
git clone https://github.com/eatingsardines/rlm_minimal_ex.git
cd rlm_minimal_ex
mix deps.get
```

Edit `.env`:

```dotenv
OPENAI_API_KEY=your-key-here
```

Start IEx:

```bash
iex -S mix
```

Paste your API key and save the file.

Run tests:

```bash
mix test
```

## Optional: Change the Model

The default model is `gpt-5.4-nano`.

If you want a different model on your machine, add this line to `.env`:

```dotenv
RLM_MINIMAL_EX_MODEL=your-openai-model
```

## Smoke Tests

### 1. Externalized context

```elixir
context = """
alpha
sentinel token: ORCHID-9137-DELTA
omega
"""

{:ok, answer, run} =
  RlmMinimalEx.run(
    context,
    "What is the sentinel token? Use the tools to inspect the externalized context before answering."
  )
```

Useful checks:

```elixir
answer
run.status
RlmMinimalEx.Trajectory.Run.pretty_timeline(run)
```

### 2. Forced delegated worker run

```elixir
context =
  String.duplicate("a", 5_000) <>
    """

    section: archive
    sentinel token: ORCHID-9137-DELTA
    """

{:ok, answer, run} =
  RlmMinimalEx.run(
    context,
    """
    Find the sentinel token.
    You must inspect the externalized context first.
    You must use delegate_subtask exactly once before giving your final answer.
    Do not answer until the delegated worker has returned.
    """
  )
```

Useful checks:

```elixir
delegate_action =
  run.root_steps
  |> Enum.flat_map(& &1.actions)
  |> Enum.find(&(&1.name == :delegate_subtask))

delegate_action.result
delegate_action.child_run.answer
RlmMinimalEx.Trajectory.Run.delegate_steps(run)
RlmMinimalEx.Trajectory.Run.pretty_timeline(run)
```

## What It Does

`RlmMinimalEx.run/3` keeps long context outside the model's initial prompt. The
model inspects that externalized context through tools, and it can delegate
focused subtasks to nested worker runs.

Each run starts:

- one `RlmMinimalEx.Environment`
- one `RlmMinimalEx.Session`

`delegate_subtask` starts another `RlmMinimalEx.run/3` with its own scoped
environment and session.

## Tool Surface

- `read_var` - Read a stored variable and get a short preview of its contents.
- `write_var` - Store a named variable when the runtime is in `:workspace` mode.
- `write_scratchpad` - Save intermediate notes under the reserved `scratch:` namespace.
- `slice_text` - Cut out a substring from a source value and optionally store it as a new variable.
- `read_text_range` - Read a character range from a stored string variable.
- `read_lines` - Read an inclusive line range from a stored string variable.
- `search_context` - Search the externalized context line by line for a query string.
- `list_vars` - List the variables currently stored in the environment with basic metadata.
- `describe_var` - Show detailed metadata and a preview for one stored variable.
- `delegate_subtask` - Start a nested worker run against the full context or a scoped variable.

## Return values

`RlmMinimalEx.run/3` returns one of:

- `{:ok, answer, run}` on success
- `{:error, reason}` when the run cannot be started
- `{:error, reason, run}` when the run starts but fails or times out

`run` includes:

- `status`
- `total_tokens`
- `root_steps` for parent-only steps
- `steps` for the flattened recursive timeline
- nested child runs on delegated actions
