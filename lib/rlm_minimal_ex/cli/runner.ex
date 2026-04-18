defmodule RlmMinimalEx.CLI.Runner do
  @moduledoc """
  Implements the interactive terminal flow for `mix rlm.chat`.

  This module owns the user-facing loop:

  - collect context from paste mode or a file
  - collect the question
  - run `RlmMinimalEx.run/3`
  - show the answer and follow-up menu

  The public `RlmMinimalEx.CLI` module stays thin and delegates here so the repo
  structure can keep CLI-specific concerns under `lib/rlm_minimal_ex/cli/`.
  """

  alias RlmMinimalEx.ChatSession
  alias RlmMinimalEx.CLI.IO
  alias RlmMinimalEx.Trajectory.Run

  @typedoc """
  Function used to execute one runtime query.
  """
  @type run_fun ::
          (term(), String.t(), keyword() ->
             {:ok, String.t(), Run.t()} | {:error, term()} | {:error, term(), Run.t()})

  @doc """
  Starts the interactive loop.

  Supported options include:

  - `:context` to preload context directly
  - `:file` to preload context from a file path
  - `:run_fun` for tests or alternative execution backends
  - `:run_opts` forwarded to `RlmMinimalEx.run/3`
  - `:io` for scripted input/output in tests
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    state =
      %{
        context: opts[:context],
        chat_session: nil,
        last_answer: nil,
        last_run: nil
      }
      |> attach_initial_context(opts)

    say(opts, "RlmMinimalEx interactive mode")
    say(opts, "One chat stays open until you choose Start over or Exit.")
    say(opts, "Follow-up questions reuse the same context and recent answers.")
    say(opts, "In paste mode, finish with /done on its own line.")
    blank(opts)

    final_state = loop(state, opts)
    cleanup_chat_session(final_state)
    :ok
  end

  defp loop(%{context: nil} = state, opts) do
    case prompt_for_context(opts) do
      {:ok, context} ->
        loop(attach_context(state, context, opts), opts)

      :halt ->
        state
    end
  end

  defp loop(%{context: context} = state, opts) do
    case prompt_query(opts) do
      {:ok, query} ->
        run_query(%{state | context: context}, query, opts)

      :halt ->
        state
    end
  end

  defp run_query(state, query, opts) do
    case ChatSession.ask(state.chat_session, query) do
      {:ok, answer, run} ->
        print_success(answer, run, opts)
        post_run_menu(%{state | last_answer: answer, last_run: run}, opts)

      {:error, reason, run} ->
        print_error(reason, run, opts)
        post_error_menu(%{state | last_run: run}, opts)
    end
  end

  defp prompt_for_context(opts) do
    case opts[:file] do
      nil ->
        prompt_context_source(opts)

      path ->
        case load_context_from_file(path) do
          {:ok, context} ->
            {:ok, context}

          {:error, reason} ->
            say(opts, "Could not read #{path}: #{format_file_error(reason)}")
            blank(opts)
            prompt_context_source(opts)
        end
    end
  end

  defp prompt_context_source(opts) do
    say(opts, "How do you want to provide context?")
    say(opts, "1. Paste text")
    say(opts, "2. Load from file")

    case IO.normalized_gets(io(opts), "> ") do
      "1" ->
        with_pasted_context(opts)

      "paste" ->
        with_pasted_context(opts)

      "2" ->
        prompt_context_file(opts)

      "file" ->
        prompt_context_file(opts)

      nil ->
        :halt

      first_line ->
        if likely_pasted_context_start?(first_line) do
          say(opts, "Treating that input as pasted context.")
          blank(opts)
          with_pasted_context(opts, first_line <> "\n")
        else
          say(opts, "Please enter 1 or 2.")
          blank(opts)
          prompt_context_source(opts)
        end
    end
  end

  defp with_pasted_context(opts, initial_content \\ "") do
    case read_pasted_context(opts, initial_content) do
      {:ok, context} ->
        if String.trim(context) == "" do
          say(opts, "Please paste some context or choose file mode.")
          blank(opts)
          prompt_context_source(opts)
        else
          {:ok, context}
        end

      {:eof, context} ->
        if String.trim(context) == "" do
          :halt
        else
          blank(opts)
          say(opts, "Paste ended with Ctrl+D.")

          # EOF closes the interactive stdin stream for the current process, so
          # we stop cleanly instead of pretending the next prompt can still read.
          say(
            opts,
            "Start `mix rlm.chat` again and finish paste with `/done` so the session stays open for your question."
          )

          :halt
        end
    end
  end

  defp read_pasted_context(opts, initial_content) do
    say(opts, "Paste your context below.")
    say(opts, "Type /done on its own line, then press Enter.")
    say(opts, "Blank lines are kept as part of the context.")

    case read_pasted_lines(opts, "") do
      {:done, content} -> {:ok, initial_content <> content}
      {:eof, content} -> {:eof, initial_content <> content}
    end
  end

  defp read_pasted_lines(opts, acc) do
    case IO.gets(io(opts), "") do
      nil ->
        {:eof, acc}

      :eof ->
        {:eof, acc}

      line ->
        # `/done` gives paste mode a portable terminator without forbidding
        # blank lines inside the pasted context itself.
        if String.trim(line) == "/done" do
          {:done, acc}
        else
          read_pasted_lines(opts, acc <> line)
        end
    end
  end

  defp prompt_context_file(opts) do
    case IO.normalized_gets(io(opts), "Path to context file: ") do
      nil ->
        :halt

      "" ->
        say(opts, "Please enter a file path.")
        blank(opts)
        prompt_context_file(opts)

      path ->
        case load_context_from_file(path) do
          {:ok, context} ->
            {:ok, context}

          {:error, reason} ->
            say(opts, "Could not read #{path}: #{format_file_error(reason)}")
            blank(opts)
            prompt_context_file(opts)
        end
    end
  end

  defp load_context_from_file(path), do: File.read(path)

  defp prompt_query(opts) do
    say(opts, "What do you want to ask?")

    case IO.normalized_gets(io(opts), "> ") do
      nil ->
        :halt

      "" ->
        say(opts, "Please enter a question.")
        blank(opts)
        prompt_query(opts)

      query ->
        {:ok, maybe_collect_multiline_query(opts, query)}
    end
  end

  defp print_success(answer, run, opts) do
    blank(opts)
    say(opts, "Run summary")
    say(opts, "Answer:")
    say(opts, answer)
    blank(opts)
    say(opts, "Status: #{run.status}")
    say(opts, "Total tokens: #{run.total_tokens}")
    say(opts, "Top-level steps: #{length(run.root_steps)}")
    say(opts, "Timeline steps: #{length(run.steps)} (includes delegated work)")
    blank(opts)
  end

  defp print_error(reason, nil, opts) do
    blank(opts)
    say(opts, "Run failed:")
    say(opts, inspect(reason))
    blank(opts)
  end

  defp print_error(reason, run, opts) do
    blank(opts)
    say(opts, "Run failed:")
    say(opts, inspect(reason))
    say(opts, "Status: #{run.status}")
    blank(opts)
  end

  defp post_run_menu(state, opts) do
    say(opts, "What next in this chat?")
    say(opts, "1. Ask a follow-up in the same chat")
    say(opts, "   Keeps the same context and recent answers.")
    say(opts, "2. Show the detailed timeline")
    say(opts, "   Shows tool calls, delegated work, and assistant text for this run.")
    say(opts, "3. Start over with new context")
    say(opts, "   Clears this chat and loads new context.")
    say(opts, "4. Exit")

    case normalize_post_run_choice(IO.normalized_gets(io(opts), "> ")) do
      "1" ->
        blank(opts)
        loop(state, opts)

      "2" ->
        blank(opts)
        say(opts, Run.detailed_timeline(state.last_run))
        blank(opts)
        post_run_menu(state, opts)

      "3" ->
        blank(opts)

        loop(
          reset_chat_state(state),
          Keyword.delete(opts, :file)
        )

      "4" ->
        state

      nil ->
        state

      _ ->
        say(opts, "Please enter 1, 2, 3, or 4.")
        blank(opts)
        post_run_menu(state, opts)
    end
  end

  defp post_error_menu(state, opts) do
    say(opts, "What next in this chat?")
    say(opts, "1. Try another question in the same chat")
    say(opts, "   Keeps the same context and prior successful answers.")
    say(opts, "2. Start over with new context")
    say(opts, "   Clears this chat and loads new context.")
    say(opts, "3. Exit")

    case normalize_post_error_choice(IO.normalized_gets(io(opts), "> ")) do
      "1" ->
        blank(opts)
        loop(state, opts)

      "2" ->
        blank(opts)

        loop(
          reset_chat_state(state),
          Keyword.delete(opts, :file)
        )

      "3" ->
        state

      nil ->
        state

      _ ->
        say(opts, "Please enter 1, 2, or 3.")
        blank(opts)
        post_error_menu(state, opts)
    end
  end

  defp normalize_post_run_choice("ask again"), do: "1"
  defp normalize_post_run_choice("timeline"), do: "2"
  defp normalize_post_run_choice("start over"), do: "3"
  defp normalize_post_run_choice("exit"), do: "4"
  defp normalize_post_run_choice(choice), do: choice

  defp normalize_post_error_choice("try again"), do: "1"
  defp normalize_post_error_choice("start over"), do: "2"
  defp normalize_post_error_choice("exit"), do: "3"
  defp normalize_post_error_choice(choice), do: choice

  defp maybe_collect_multiline_query(opts, query) do
    if likely_multiline_query_start?(query) do
      case read_immediate_query_continuation(opts, []) do
        [] -> query
        continuation -> query <> "\n" <> Enum.join(continuation, "")
      end
    else
      query
    end
  end

  defp read_immediate_query_continuation(opts, acc) do
    case IO.gets_nowait(io(opts), "", 10) do
      nil ->
        Enum.reverse(acc)

      :eof ->
        Enum.reverse(acc)

      line ->
        if String.trim(line) == "/done" do
          Enum.reverse(acc)
        else
          read_immediate_query_continuation(opts, [line | acc])
        end
    end
  end

  defp likely_pasted_context_start?(input) do
    String.contains?(input, [" ", "\t"]) ||
      String.length(input) > 16 ||
      String.match?(input, ~r/[[:punct:]]/)
  end

  defp likely_multiline_query_start?(input) do
    String.length(input) >= 80 ||
      String.contains?(input, ":") ||
      String.starts_with?(input, ["- ", "* ", "1. ", "2. "])
  end

  defp attach_initial_context(%{context: nil} = state, _opts), do: state

  defp attach_initial_context(state, opts) do
    attach_context(state, state.context, opts)
  end

  defp attach_context(state, context, opts) do
    session_pid =
      case state.chat_session do
        nil ->
          {:ok, pid} = ChatSession.start(chat_session_opts(context, opts))
          pid

        pid ->
          :ok = ChatSession.update_context(pid, context)
          pid
      end

    %{state | context: context, chat_session: session_pid, last_answer: nil, last_run: nil}
  end

  defp reset_chat_state(state) do
    cleanup_chat_session(state)
    %{state | context: nil, chat_session: nil, last_answer: nil, last_run: nil}
  end

  defp cleanup_chat_session(%{chat_session: nil} = state), do: state

  defp cleanup_chat_session(%{chat_session: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      ChatSession.stop(pid)
    end

    %{state | chat_session: nil}
  end

  defp chat_session_opts(context, opts) do
    [context: context, run_opts: opts[:run_opts] || []]
    |> maybe_put(:run_fun, opts[:run_fun])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_file_error(:enoent), do: "file not found"
  defp format_file_error(reason), do: :file.format_error(reason) |> to_string()

  defp io(opts), do: Keyword.get(opts, :io, IO.default())
  defp say(opts, message), do: IO.puts(io(opts), message)
  defp blank(opts), do: say(opts, "")
end
