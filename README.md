# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

This repo keeps the minimal runtime kernel plus the parity upgrades needed to
make the externalized-context workflow practical on the BEAM:

- `RlmMinimalEx.run/3`
- per-run supervision
- externalized run state in `Environment`
- a model turn loop in `Session`
- typed tool definitions in `Actions`
- structured run traces in `Trajectory`
- delegated nested worker sessions via `Task.Supervisor`

The root model does not receive the full `context` in its initial prompt.
Instead, the context is stored in environment-owned state and must be inspected
through tools.

## Runtime shape

A single `RlmMinimalEx.run/3` call starts a per-run supervision tree with:

- one `RlmMinimalEx.Environment`
- one `RlmMinimalEx.Session`

The coordinator session:

1. starts with only the system prompt and the user query
2. offers the model a typed tool surface
3. executes any tool calls against the environment or session
4. appends tool results back into the message history
5. repeats until the model returns plain text

Delegated workers now run as nested `RlmMinimalEx.run/3` calls with their own
scoped environment and session, so `delegate_subtask` is recursive runtime
behavior rather than a one-shot prompt wrapper.

## Tool surface

Current tools exposed to the coordinator and nested workers:

- `read_var`: read a stored variable with a preview
- `write_var`: write a variable in `:workspace` lane
- `write_scratchpad`: write intermediate text in `:read_only` under the reserved `scratch:` namespace
- `slice_text`: extract, store, and return a substring from a source variable
- `read_text_range`: read a character range from a stored string variable
- `read_lines`: read an inclusive line range from a stored string variable
- `search_context`: search the externalized context by line
- `list_vars`: list stored variables with metadata
- `describe_var`: inspect metadata and preview for one variable
- `delegate_subtask`: run a nested worker session against the full scoped context or a scoped variable

## Runtime semantics

- Context is externalized. The model should inspect it with tools before answering.
- Scratchpad writes are allowed in `:read_only` through `write_scratchpad`.
- General writes remain lane-gated through `write_var`.
- Delegated workers inherit the runtime model function and run their own tool loop.
- Max-turn exhaustion is explicit: the runtime returns `{:error, :max_turns_exceeded, run}` and sets `run.status` to `:timeout`.
- Model, action, and token metadata are recorded in the returned trajectory.

## Install

```bash
cd /path/to/rlm_minimal_ex
mix deps.get
```

## Test

```bash
mix test
```

## Live smoke tests

Set your API key:

```bash
export OPENAI_API_KEY="your-key-here"
```

Optional model override:

```bash
export RLM_MINIMAL_EX_MODEL="gpt-5.4-nano"
```

Start IEx:

```bash
iex -S mix
```

### 1. Externalized context inspection

Run:

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

The token lives in environment-owned state, not in the initial prompt. A
healthy run should show at least one inspection tool such as `search_context`,
`read_var`, `read_text_range`, or `read_lines` before the final answer.

### 2. Delegated nested worker run

Run:

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
    Inspect the externalized context first.
    If helpful, delegate a focused subtask to a worker after you have identified the relevant chunk.
    """
  )
```

A healthy nested-worker run should:

- inspect the externalized context before answering
- optionally store intermediate notes in `scratch:...`
- show a `delegate_subtask` action in the trajectory if the coordinator decides to delegate
- let the worker inspect its own scoped externalized context through tools before it answers

## Return values

`RlmMinimalEx.run/3` returns one of:

- `{:ok, answer, run}` on success
- `{:error, reason}` when the run cannot be started
- `{:error, reason, run}` when the run starts but fails or times out

`run` is a structured trajectory that includes ordered steps, actions, token
totals, and final status.
