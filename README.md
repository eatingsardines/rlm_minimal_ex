# RlmMinimalEx

Minimal BEAM-native runtime for recursive LLM work.

`RlmMinimalEx` is a small OTP runtime for tool using model loops. It keeps
large context out of the initial prompt, exposes a typed tool surface, supports
nested worker delegation, records structured run traces, and ships with both an
interactive CLI and a bundled OpenAI backend.

## Quick Start

```bash
git clone https://github.com/eatingsardines/rlm_minimal_ex.git
cd rlm_minimal_ex
mix deps.get
```

For the interactive CLI, set your key in `.env`:

```dotenv
OPENAI_API_KEY=your-key-here
```

Run the project checks:

```bash
mix check
```

Start the interactive chat:

```bash
mix rlm.chat
```

You can also preload context from a file:

```bash
mix rlm.chat --file path/to/context.txt
```

## Using It From Elixir

Run one query against externalized context:

```elixir
{:ok, answer, run} =
  RlmMinimalEx.run("""
  BEAM schedulers run Erlang processes concurrently.
  """, "What does this say about concurrency?")
```

Use `:workspace` lane when you want normal writes to be available:

```elixir
{:ok, answer, run} =
  RlmMinimalEx.run(context, query,
    lane: :workspace,
    max_turns: 10
  )
```

`run!/3` returns only the final answer and raises on failure:

```elixir
answer = RlmMinimalEx.run!(context, query)
```

## Runtime Capabilities

At a high level, the runtime provides:

- externalized run context instead of putting the whole document in the prompt
- typed tool calls for inspecting and slicing that context
- nested delegated worker runs for scoped subtasks
- structured traces describing model calls, tool actions, and final outcomes
- an interactive CLI with same chat follow-up continuity

## Model Backend

The bundled backend uses OpenAI and reads `OPENAI_API_KEY`.

You can override the model per run or per chat with:

- `RLM_MINIMAL_EX_MODEL`
- `mix rlm.chat --model ...`
- `RlmMinimalEx.run(..., model: ...)`

If you want a different backend, the runtime also accepts a custom `model_fn/3`.

## Return Values

`RlmMinimalEx.run/3` returns one of:

- `{:ok, answer, run}` on success
- `{:error, reason, run}` on failure or timeout

`run` contains the structured trace for that execution, including status, token
counts, step data, and any nested delegated child runs.

## Diagnostics

The repo includes a live diagnostics task:

```bash
mix rlm.diagnostics
```

This is mainly for inspecting active chats and runs while the app is live.

## License

Apache-2.0. See [LICENSE](LICENSE).
