defmodule RlmMinimalEx.CLIIO do
  @moduledoc false

  def default do
    %{
      puts: &IO.puts/1,
      gets: &IO.gets/1
    }
  end

  def puts(io, message), do: io.puts.(message)
  def gets(io, prompt), do: io.gets.(prompt)

  def normalized_gets(io, prompt) do
    case gets(io, prompt) do
      nil -> nil
      :eof -> nil
      line -> String.trim(line)
    end
  end
end
