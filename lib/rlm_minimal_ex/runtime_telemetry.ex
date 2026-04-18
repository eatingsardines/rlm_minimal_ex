defmodule RlmMinimalEx.RuntimeTelemetry do
  @moduledoc """
  Tiny wrapper around `:telemetry.execute/3` for runtime events.

  All events are emitted under the `[:rlm_minimal_ex, ...]` prefix.
  """

  @prefix [:rlm_minimal_ex]

  @doc """
  Emits one runtime telemetry event.
  """
  def execute(event_suffix, measurements, metadata \\ %{}) do
    :telemetry.execute(@prefix ++ event_suffix, measurements, metadata)
  end
end
