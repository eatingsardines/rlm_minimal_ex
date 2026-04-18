defmodule RlmMinimalEx.CLI.IO do
  @moduledoc """
  Small terminal IO adapter for the interactive CLI.

  The runner depends on this module instead of calling `IO` directly so tests
  can inject scripted input/output without touching real stdin or stdout.
  """

  @doc """
  Returns the default terminal IO implementation backed by `IO`.
  """
  def default do
    %{
      puts: &IO.puts/1,
      gets: &IO.gets/1
    }
  end

  @doc """
  Writes a line to the configured IO target.
  """
  def puts(io, message), do: io.puts.(message)

  @doc """
  Reads one line from the configured IO target.
  """
  def gets(io, prompt), do: io.gets.(prompt)

  @doc """
  Reads one line if input is immediately available, otherwise returns `nil`.
  """
  def gets_nowait(io, prompt, timeout_ms \\ 10) do
    case gets_nowait_fun(io) do
      {:arity_2, fun} ->
        fun.(prompt, timeout_ms)

      {:arity_1, fun} ->
        fun.(prompt)

      nil ->
        gets_with_timeout(io, prompt, timeout_ms)
    end
  end

  @doc """
  Reads and trims one line, normalizing EOF-like values to `nil`.
  """
  def normalized_gets(io, prompt) do
    case gets(io, prompt) do
      nil -> nil
      :eof -> nil
      line -> String.trim(line)
    end
  end

  @doc """
  Reads one line if input is immediately available and trims it, normalizing
  EOF-like values to `nil`.
  """
  def normalized_gets_nowait(io, prompt, timeout_ms \\ 10) do
    case gets_nowait(io, prompt, timeout_ms) do
      nil -> nil
      :eof -> nil
      line -> String.trim(line)
    end
  end

  defp gets_nowait_fun(io) do
    cond do
      Map.has_key?(io, :gets_nowait) and is_function(io.gets_nowait, 2) ->
        {:arity_2, io.gets_nowait}

      Map.has_key?(io, :gets_nowait) and is_function(io.gets_nowait, 1) ->
        {:arity_1, io.gets_nowait}

      true ->
        nil
    end
  end

  defp gets_with_timeout(io, prompt, timeout_ms) do
    task = Task.async(fn -> gets(io, prompt) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, nil} -> nil
      {:ok, :eof} -> nil
      {:ok, line} -> line
      nil -> nil
    end
  end
end
