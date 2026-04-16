defmodule RlmMinimalEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :rlm_minimal_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RlmMinimalEx.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end
end
