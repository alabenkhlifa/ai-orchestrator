defmodule SddOrchestrator.ProjectAssistant.FakeRepositoryObservationAdapter do
  @moduledoc """
  Deterministic `RepositoryObservationAdapter` test double for specs/12 Task
  4. No worker access, no network.

  Scenarios are keyed off `request.repository_ref`, mirroring
  `SddOrchestrator.GitHubIntegration.FakeProvider`'s login-prefix convention:

    * `"clean"` — a stable, non-dirty tree with a commit.
    * `"dirty"` — a stable tree with uncommitted changes.
    * `"unborn"` — a `.git` directory with zero commits (`commit: nil`),
      mirroring `RepositoryInitialization.Eligibility`'s `:unborn_repository`
      classification.
    * `"unstable"` — relevant working-tree state changes between the scan's
      start and its completion (before/after digests differ).
    * `"fails:" <> reason` — the adapter itself fails with `:error, reason`,
      independent of worker-availability denial.
    * any other value — the same as `"clean"`, so a caller that only cares
      about authorization outcomes need not pick a scenario.
  """
  @behaviour SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

  @impl true
  def observe(%{repository_ref: "fails:" <> reason}), do: {:error, String.to_atom(reason)}

  def observe(%{repository_ref: "dirty"} = request), do: {:ok, result(request, dirty: true)}

  def observe(%{repository_ref: "unborn"} = request),
    do: {:ok, result(request, commit: nil, branch: "main")}

  def observe(%{repository_ref: "unstable"} = request),
    do: {:ok, result(request, after_digest: "digest-after-changed")}

  def observe(request), do: {:ok, result(request, [])}

  defp result(request, overrides) do
    started = ~U[2026-01-01 12:00:00Z]
    completed = DateTime.add(started, 4, :second)

    %{
      branch: "main",
      commit: "abc123def456",
      dirty: false,
      scan_started_at: started,
      scan_completed_at: completed,
      exclusions: Map.get(request, :exclusions, []),
      before_digest: "digest-stable",
      after_digest: "digest-stable"
    }
    |> Map.merge(Map.new(overrides))
  end
end
