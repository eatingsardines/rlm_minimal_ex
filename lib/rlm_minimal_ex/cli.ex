defmodule RlmMinimalEx.CLI do
  @moduledoc """
  Interactive terminal interface for `RlmMinimalEx`.
  """

  alias RlmMinimalEx.Trajectory.Run

  @type run_fun ::
          (term(), String.t(), keyword() ->
             {:ok, String.t(), Run.t()} | {:error, term()} | {:error, term(), Run.t()})

  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    state = %{
      context: opts[:context],
      last_answer: nil,
      last_run: nil
    }

    puts("RlmMinimalEx interactive mode")
    puts("")

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
    case prompt_query() do
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
        print_success(answer, run)
        post_run_menu(%{state | last_answer: answer, last_run: run}, opts)

      {:error, reason, run} ->
        print_error(reason, run)
        post_error_menu(%{state | last_run: run}, opts)

      {:error, reason} ->
        print_error(reason, nil)
        post_error_menu(state, opts)
    end
  end

  defp prompt_for_context(opts) do
    case opts[:file] do
      nil ->
        prompt_context_source()

      path ->
        case load_context_from_file(path) do
          {:ok, context} ->
            {:ok, context}

          {:error, reason} ->
            puts("Could not read #{path}: #{format_file_error(reason)}")
            puts("")
            prompt_context_source()
        end
    end
  end

  defp prompt_context_source do
    puts("How do you want to provide context?")
    puts("1. Paste text")
    puts("2. Load from file")

    case normalized_gets("> ") do
      "1" ->
        {:ok, read_pasted_context()}

      "paste" ->
        {:ok, read_pasted_context()}

      "2" ->
        prompt_context_file()

      "file" ->
        prompt_context_file()

      nil ->
        :halt

      _ ->
        puts("Please enter 1 or 2.")
        puts("")
        prompt_context_source()
    end
  end

  defp read_pasted_context do
    puts("Paste your context below.")
    puts("Finish with a blank line.")
    puts("If your context needs blank lines, use file mode instead.")

    collect_context_lines([])
  end

  defp collect_context_lines(lines) do
    case IO.gets("") do
      nil ->
        lines
        |> Enum.reverse()
        |> Enum.join()

      :eof ->
        lines
        |> Enum.reverse()
        |> Enum.join()

      line ->
        if String.trim(line) == "" and lines != [] do
          lines
          |> Enum.reverse()
          |> Enum.join()
        else
          collect_context_lines([line | lines])
        end
    end
  end

  defp prompt_context_file do
    case normalized_gets("Path to context file: ") do
      nil ->
        :halt

      "" ->
        puts("Please enter a file path.")
        puts("")
        prompt_context_file()

      path ->
        case load_context_from_file(path) do
          {:ok, context} ->
            {:ok, context}

          {:error, reason} ->
            puts("Could not read #{path}: #{format_file_error(reason)}")
            puts("")
            prompt_context_file()
        end
    end
  end

  defp load_context_from_file(path) do
    File.read(path)
  end

  defp prompt_query do
    puts("What do you want to ask?")

    case normalized_gets("> ") do
      nil ->
        :halt

      "" ->
        puts("Please enter a question.")
        puts("")
        prompt_query()

      query ->
        {:ok, query}
    end
  end

  defp print_success(answer, run) do
    puts("")
    puts("Answer:")
    puts(answer)
    puts("")
    puts("Status: #{run.status}")
    puts("Tokens: #{run.total_tokens}")
    puts("Root steps: #{length(run.root_steps)}")
    puts("Timeline steps: #{length(run.steps)}")
    puts("")
  end

  defp print_error(reason, nil) do
    puts("")
    puts("Run failed:")
    puts(inspect(reason))
    puts("")
  end

  defp print_error(reason, run) do
    puts("")
    puts("Run failed:")
    puts(inspect(reason))
    puts("Status: #{run.status}")
    puts("")
  end

  defp post_run_menu(state, opts) do
    puts("What next?")
    puts("1. Ask another question about the same context")
    puts("2. Show the detailed timeline")
    puts("3. Start over with new context")
    puts("4. Exit")

    case normalized_gets("> ") do
      "1" ->
        puts("")
        loop(state, opts)

      "ask again" ->
        puts("")
        loop(state, opts)

      "2" ->
        puts("")
        puts(Run.detailed_timeline(state.last_run))
        puts("")
        post_run_menu(state, opts)

      "timeline" ->
        puts("")
        puts(Run.detailed_timeline(state.last_run))
        puts("")
        post_run_menu(state, opts)

      "3" ->
        puts("")

        loop(
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "start over" ->
        puts("")

        loop(
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "4" ->
        :ok

      "exit" ->
        :ok

      nil ->
        :ok

      _ ->
        puts("Please enter 1, 2, 3, or 4.")
        puts("")
        post_run_menu(state, opts)
    end
  end

  defp post_error_menu(state, opts) do
    puts("What next?")
    puts("1. Try another question with the same context")
    puts("2. Start over with new context")
    puts("3. Exit")

    case normalized_gets("> ") do
      "1" ->
        puts("")
        loop(state, opts)

      "try again" ->
        puts("")
        loop(state, opts)

      "2" ->
        puts("")

        loop(
          %{state | context: nil, last_answer: nil, last_run: nil},
          Keyword.delete(opts, :file)
        )

      "start over" ->
        puts("")

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
        puts("Please enter 1, 2, or 3.")
        puts("")
        post_error_menu(state, opts)
    end
  end

  defp normalized_gets(prompt) do
    case IO.gets(prompt) do
      nil -> nil
      :eof -> nil
      line -> String.trim(line)
    end
  end

  defp format_file_error(:enoent), do: "file not found"
  defp format_file_error(reason), do: :file.format_error(reason) |> to_string()

  defp puts(message), do: IO.puts(message)
end
