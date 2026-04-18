defmodule RlmMinimalEx.Env do
  @moduledoc """
  Minimal `.env` loader for local development.

  The loader is intentionally small:

  - reads `.env` from the current working directory
  - ignores blank lines and comments
  - supports optional `export KEY=value`
  - preserves variables already present in the OS environment
  """

  @dotenv_path ".env"

  @doc """
  Loads `.env` into the current process environment when the file exists.
  Existing OS environment variables win over `.env`.
  """
  @spec load_dotenv(Path.t()) :: :ok
  def load_dotenv(path \\ @dotenv_path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split(~r/\r\n|\n|\r/, trim: false)
      |> Enum.each(&load_line/1)
    end

    :ok
  end

  defp load_line(line) do
    line = String.trim(line)

    cond do
      line == "" -> :ok
      String.starts_with?(line, "#") -> :ok
      true -> maybe_put_env(parse_assignment(line))
    end
  end

  defp parse_assignment("export " <> rest), do: parse_assignment(rest)

  defp parse_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)
        value = raw_value |> String.trim() |> trim_quotes()

        if key == "" do
          :error
        else
          {:ok, key, value}
        end

      _ ->
        :error
    end
  end

  defp maybe_put_env({:ok, key, value}) do
    if System.get_env(key) == nil do
      System.put_env(key, value)
    end
  end

  defp maybe_put_env(:error), do: :ok

  defp trim_quotes(<<"\"", rest::binary>>) do
    String.trim_trailing(rest, "\"")
  end

  defp trim_quotes(<<"'", rest::binary>>) do
    String.trim_trailing(rest, "'")
  end

  defp trim_quotes(value), do: value
end
