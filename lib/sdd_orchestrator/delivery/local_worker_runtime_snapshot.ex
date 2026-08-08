defmodule SddOrchestrator.Delivery.LocalWorkerRuntimeSnapshot do
  @moduledoc """
  Computes a governed local-worker run's live runtime snapshot on read.

  A local-worker run's real coding work never talks to the Codex App Server and
  can never honestly pass `ObservationAdapter.validate_provenance/3`'s
  Codex-official-client-only gate, so this reads the run's own already-loaded
  state instead of persisting an observation (see
  specs/34-local-worker-runtime-governance/design.md, "A live computed snapshot
  instead of a persisted, ingested observation"). Tokens and cost are always
  reported unknown, never estimated.
  """

  alias SddOrchestrator.Delivery.{AgentRun, RunAttempt}

  @type t :: %{
          elapsed_seconds: non_neg_integer(),
          status: String.t(),
          tokens: :unknown,
          cost: :unknown
        }

  @spec snapshot(AgentRun.t(), RunAttempt.t(), keyword()) :: t()
  def snapshot(%AgentRun{}, %RunAttempt{} = attempt, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      elapsed_seconds: elapsed_seconds(attempt.inserted_at, now),
      status: attempt.state,
      tokens: :unknown,
      cost: :unknown
    }
  end

  defp elapsed_seconds(inserted_at, now) do
    now
    |> DateTime.diff(inserted_at, :second)
    |> max(0)
  end
end
