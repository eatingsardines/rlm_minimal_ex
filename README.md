# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

This repo keeps the minimal runtime kernel plus the parity upgrades that make
the externalized-context workflow practical on the BEAM:

- `RlmMinimalEx.run/3`
- per-run supervision
- externalized run state in `Environment`
- a model turn loop in `Session`
- typed tool definitions in `Actions`
- structured run traces in `Trajectory`
- delegated nested worker sessions via `Task.Supervisor`

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

Paste your API key and save the file.

Start IEx:

```bash
iex -S mix
```

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

## Runtime Shape

The root model does not receive the full `context` in its initial prompt.
Instead, the context is stored in environment-owned state and must be inspected
through tools.

A single `RlmMinimalEx.run/3` call starts a per-run supervision tree with:

- one `RlmMinimalEx.Environment`
- one `RlmMinimalEx.Session`

The coordinator session:

1. starts with only the system prompt and the user query
2. offers the model a typed tool surface
3. executes any tool calls against the environment or session
4. appends tool results back into the message history
5. repeats until the model returns plain text

`delegate_subtask` starts a nested `RlmMinimalEx.run/3` with its own scoped
environment and session, so delegated work is real recursive runtime behavior
rather than a one-shot prompt wrapper.

## Runtime Semantics

- Context is externalized. The model should inspect it with tools before answering.
- Scratchpad writes are allowed in `:read_only` through `write_scratchpad`.
- General writes remain lane-gated through `write_var`.
- Delegated workers inherit the runtime model function and run their own tool loop.
- Max-turn exhaustion is explicit: the runtime returns `{:error, :max_turns_exceeded, run}` and sets `run.status` to `:timeout`.
- Model, action, and token metadata are recorded in the returned trajectory.

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

## Return Values

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
