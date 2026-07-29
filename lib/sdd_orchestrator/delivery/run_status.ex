defmodule SddOrchestrator.Delivery.RunStatus do
  @moduledoc """
  The visible status a run gives its feature.

  `Blocked` and `Failed` are statuses, never columns. A run that pauses on a
  product question or exhausts its retry budget keeps its place in
  `In development`, because losing that position would tell a reader the work
  went backwards when it did not.

  Only a live or terminally failed run contributes a status. A completed or
  canceled run leaves the feature to whatever column it moved to, so a finished
  run never keeps decorating a card.
  """

  alias SddOrchestrator.Delivery.AgentRun

  @statuses %{
    "blocked" => "blocked",
    "failed" => "failed"
  }

  @labels %{
    "blocked" => "Blocked",
    "failed" => "Failed"
  }

  @spec for_run(AgentRun.t() | nil) :: String.t()
  def for_run(nil), do: "none"
  def for_run(%AgentRun{state: state}), do: Map.get(@statuses, state, "none")

  @spec label(String.t()) :: String.t() | nil
  def label(status), do: Map.get(@labels, status)

  @doc """
  Whether a run is still doing something a reader should wait for.

  Used to decide whether the feature detail shows live progress or a settled
  result.
  """
  @spec live?(AgentRun.t() | nil) :: boolean()
  def live?(nil), do: false
  def live?(%AgentRun{state: state}), do: state in ~w(pending running blocked)

  @doc "A short reason for a failed run, or nil when there is nothing to say."
  @spec reason(AgentRun.t() | nil) :: String.t() | nil
  def reason(%AgentRun{state: "failed", failure_reason: reason}), do: reason
  def reason(_run), do: nil
end
