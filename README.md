# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

This repo includes:

- `RlmMinimalEx.run/3` to start a run
- per-run supervision
- externalized context in `Environment`
- a model turn loop in `Session`
- typed tools in `Actions`
- structured traces in `Trajectory`
- nested worker sessions via `Task.Supervisor`

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

Run tests from your shell:

```bash
mix test
```

One test intentionally crashes a delegated worker. If you see `worker exploded!`
but the suite still passes, that is expected.

Start the interactive CLI:

```bash
mix rlm.chat
```

The CLI will ask for your context and question.

## Optional: Change the Model

The default model is `gpt-5.4-nano`.

If you want a different model on your machine, add this line to `.env`:

```dotenv
RLM_MINIMAL_EX_MODEL=your-openai-model
```

## Runtime Shape

The root model does not receive the full `context` in its initial prompt.
Context lives in `Environment` and is inspected through tools.

Each `RlmMinimalEx.run/3` starts one `RlmMinimalEx.Environment` and one
`RlmMinimalEx.Session`.

The session:

1. starts with the system prompt and user query
2. offers the model the tool surface
3. executes tool calls
4. appends tool results to message history
5. repeats until the model returns plain text

`delegate_subtask` starts a nested run with its own scoped environment and
session.

## Runtime Semantics

- Context is externalized. The model should inspect it with tools before answering.
- Scratchpad writes are allowed in `:read_only` through `write_scratchpad`.
- General writes still depend on the current lane and go through `write_var`.
- Delegated workers inherit the same model function and run their own tool loop.
- If the run hits max turns, it returns `{:error, :max_turns_exceeded, run}` and sets `run.status` to `:timeout`.
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
- `delegate_subtask` - Start a nested worker run against the full context or one stored variable.

## Return Values

`RlmMinimalEx.run/3` returns one of:

- `{:ok, answer, run}` on success
- `{:error, reason}` when the run cannot be started
- `{:error, reason, run}` when the run starts but fails or times out

`run` includes:

- `status`
- `total_tokens`
- `root_steps`
- `steps`
- nested child runs on delegated actions
