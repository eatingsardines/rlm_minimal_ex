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
  Reads and trims one line, normalizing EOF-like values to `nil`.
  """
  def normalized_gets(io, prompt) do
    case gets(io, prompt) do
      nil -> nil
      :eof -> nil
      line -> String.trim(line)
    end
  end
end
