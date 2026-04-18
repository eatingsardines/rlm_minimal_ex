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
    state = %{
      context: opts[:context],
      last_answer: nil,
      last_run: nil
    }

    say(opts, "RlmMinimalEx interactive mode")
    blank(opts)

    loop(state, opts)
  end

  defp loop(%{context: nil} = state, opts) do
    case prompt_for_context(opts) do
      {:ok, context} ->
        loop(%{state | context: context}, opts)

      :halt ->
        :ok
    end
  end

  defp loop(%{context: context} = state, opts) do
    case prompt_query(opts) do
      {:ok, query} ->
        run_query(%{state | context: context}, query, opts)

      :halt ->
        :ok
    end
  end

  defp run_query(state, query, opts) do
    run_fun = opts[:run_fun] || (&RlmMinimalEx.run/3)
    run_opts = opts[:run_opts] || []

    case run_fun.(state.context, query, run_opts) do
      {:ok, answer, run} ->
        print_success(answer, run, opts)
        post_run_menu(%{state | last_answer: answer, last_run: run}, opts)

      {:error, reason, run} ->
        print_error(reason, run, opts)
        post_error_menu(%{state | last_run: run}, opts)

      {:error, reason} ->
        print_error(reason, nil, opts)
        post_error_menu(state, opts)
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

      # Treat unexpected input as the first pasted line so users who paste too
      # early do not get trapped in a validation loop.
      first_line ->
        with_pasted_context(opts, first_line <> "\n")
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
        {:ok, query}
    end
  end

  defp print_success(answer, run, opts) do
    blank(opts)
    say(opts, "Answer:")
    say(opts, answer)
    blank(opts)
    say(opts, "Status: #{run.status}")
    say(opts, "Tokens: #{run.total_tokens}")
    say(opts, "Root steps: #{length(run.root_steps)}")
    say(opts, "Timeline steps: #{length(run.steps)}")
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
    say(opts, "What next?")
    say(opts, "1. Ask another question about the same context")
    say(opts, "2. Show the detailed timeline")
    say(opts, "3. Start over with new context")
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
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "4" ->
        :ok

      nil ->
        :ok

      _ ->
        say(opts, "Please enter 1, 2, 3, or 4.")
        blank(opts)
        post_run_menu(state, opts)
    end
  end

  defp post_error_menu(state, opts) do
    say(opts, "What next?")
    say(opts, "1. Try another question with the same context")
    say(opts, "2. Start over with new context")
    say(opts, "3. Exit")

    case IO.normalized_gets(io(opts), "> ") do
      "1" ->
        blank(opts)
        loop(state, opts)

      "try again" ->
        blank(opts)
        loop(state, opts)

      "2" ->
        blank(opts)

        loop(
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "start over" ->
        blank(opts)

        loop(
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "3" ->
        :ok

      "exit" ->
        :ok

      nil ->
        :ok

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

  defp format_file_error(:enoent), do: "file not found"
  defp format_file_error(reason), do: :file.format_error(reason) |> to_string()

  defp io(opts), do: Keyword.get(opts, :io, IO.default())
  defp say(opts, message), do: IO.puts(io(opts), message)
  defp blank(opts), do: say(opts, "")
end
