# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

This repo keeps only the phase-1 kernel:

- `RlmMinimalEx.run/3`
- per-run supervision
- externalized state in `Environment`
- a model turn loop in `Session`
- typed tool definitions in `Actions`
- structured run traces in `Trajectory`
- delegated one-shot worker tasks via `Task.Supervisor`

## Install

```bash
cd /path/to/rlm_minimal_ex
mix deps.get
```

## Test

```bash
mix test
```

## Live smoke test

Set your API key:

```bash
export OPENAI_API_KEY="your-key-here"
```

Optional model override:

```bash
export RLM_MINIMAL_EX_MODEL="gpt-4o"
```

Start IEx:

```bash
iex -S mix
```

Then run:

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

The token lives in environment-owned state, not in the initial prompt. A valid
phase-1 smoke test should show the model using `search_context` or `read_var`
before it answers.
