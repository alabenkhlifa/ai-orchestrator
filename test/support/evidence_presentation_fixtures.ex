defmodule SddOrchestrator.EvidencePresentationFixtures do
  @moduledoc """
  Recorded evidence for the presentation proof (Task 31).

  These fixtures write through `DeliveryStore` rather than through `Repo`, so a
  scenario means the same thing under the hosted database and under the
  worker-owned device store, and a superseded item is linked by the same
  operation the ingestion path uses.

  They deliberately do not go through `EvidenceIngestion`. What is being proved
  here is presentation of records that already exist; rebuilding a signed worker
  envelope, a fence, and a sequence for each one would prove the ingestion path
  again and make the recorded shape harder to see.
  """

  alias SddOrchestrator.Delivery.DeliveryStore
  alias SddOrchestrator.Delivery.VerificationCompletion.Verdict
  alias SddOrchestrator.DeliveryFixtures

  @commit "a1b2c3d4e5f6a7b8c9d0"

  @doc "The commit these fixtures record proof against unless told otherwise."
  def commit, do: @commit

  @doc """
  Creates one run and its first attempt through the project's own store.

  A run inserted straight into `Repo` would be invisible to a device-authoritative
  project, so the run every scenario here records evidence against is committed
  the same way the product commits one.
  """
  def run_fixture(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/feature-#{unique}"
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            fence_token: 1
          }}}
      ])

    %{run: run, attempt: attempt}
  end

  @doc """
  Records one item of evidence through the project's own storage authority.

  A required check keeps its command and exit code, because a check outcome with
  no exit provenance is exactly what the record refuses.
  """
  def evidence_fixture(authority, %{run: run, attempt: attempt}, attrs \\ %{}) do
    attrs = Map.new(attrs)
    kind = Map.get(attrs, :kind, "required_check")
    name = Map.get(attrs, :name, "mix test")

    {:ok, %{evidence: evidence}} =
      DeliveryStore.commit(authority, run.project_id, [
        {:evidence,
         {:insert_evidence,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: Map.get(attrs, :attempt_id, attempt.id),
            command_id: Map.get(attrs, :command_id, Ecto.UUID.generate()),
            kind: kind,
            name: name,
            outcome: Map.get(attrs, :outcome, "passed"),
            command: Map.get(attrs, :command, default_command(kind, name)),
            exit_code: Map.get(attrs, :exit_code, default_exit_code(kind)),
            duration_ms: Map.get(attrs, :duration_ms, 4_200),
            branch: run.branch,
            commit_sha: Map.get(attrs, :commit_sha, @commit),
            source: Map.get(attrs, :source, "check"),
            recorded_at: Map.get(attrs, :recorded_at, DateTime.utc_now()),
            digest: Map.get(attrs, :digest, DeliveryFixtures.digest(name)),
            redacted: Map.get(attrs, :redacted, false),
            artifact_ref: Map.get(attrs, :artifact_ref)
          }}}
      ])

    evidence
  end

  @doc """
  Records one captured screenshot together with the bytes it addresses.

  The artifact is stored first and the digest is computed from those exact
  bytes, because a screenshot record whose digest addresses something else is
  refused everywhere else in the product and would prove nothing here.
  """
  def screenshot_fixture(authority, %{run: run} = context, attrs \\ %{}) do
    attrs = Map.new(attrs)
    name = Map.get(attrs, :name, "feature screen")
    content = Map.get(attrs, :content, DeliveryFixtures.png_bytes(name))
    redacted = Map.get(attrs, :redacted, false)

    ref =
      DeliveryFixtures.artifact_fixture(authority, run.project_id,
        content: content,
        content_type: Map.get(attrs, :content_type, "image/png"),
        redacted: redacted
      )

    evidence_fixture(
      authority,
      context,
      attrs
      |> Map.merge(%{
        kind: "screenshot",
        name: name,
        outcome: Map.get(attrs, :outcome, "passed"),
        source: Map.get(attrs, :source, "worker"),
        digest: DeliveryFixtures.content_digest(content),
        artifact_ref: ref,
        redacted: redacted
      })
      |> Map.delete(:content)
      |> Map.delete(:content_type)
    )
  end

  @doc "Links one recorded item to the later item that replaced it."
  def supersede_fixture(authority, superseded, replacement) do
    {:ok, _results} =
      DeliveryStore.commit(authority, superseded.project_id, [
        {:superseded, {:supersede_evidence, superseded, replacement.id}}
      ])

    :ok
  end

  @doc """
  Appends the completion gate's own conclusion as one activity entry.

  The payload comes from `Verdict.payload/1` rather than from a hand-written
  map, so the presentation is read against the exact projection the gate writes.
  """
  def verdict_fixture(authority, %{run: run, attempt: attempt}, %Verdict{} = verdict) do
    {:ok, %{activity: entry}} =
      DeliveryStore.commit(authority, run.project_id, [
        {:activity,
         {:append_activity,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: attempt.id,
            actor_kind: "agent",
            type: verdict_type(verdict),
            payload: Verdict.payload(verdict)
          }}}
      ])

    entry
  end

  @doc "One refused verdict naming the checks behind the refusal."
  def refused_verdict(%{run: run, attempt: attempt}, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %Verdict{
      outcome: :refused,
      reason: Map.get(attrs, :reason, :required_check_failed),
      run_id: run.id,
      attempt_id: attempt.id,
      attempt_number: attempt.attempt_number,
      branch: run.branch,
      revision_id: attempt.effective_revision_id,
      commit_sha: Map.get(attrs, :commit_sha, @commit),
      required: Map.get(attrs, :required, []),
      passed: Map.get(attrs, :passed, []),
      failed: Map.get(attrs, :failed, []),
      missing: Map.get(attrs, :missing, []),
      unsupported: Map.get(attrs, :unsupported, []),
      screenshots_failed: Map.get(attrs, :screenshots_failed, [])
    }
  end

  defp verdict_type(verdict) do
    if Verdict.verified?(verdict), do: "verification_completed", else: "verification_refused"
  end

  defp default_command("required_check", name), do: name
  defp default_command(_kind, _name), do: nil

  defp default_exit_code("required_check"), do: 0
  defp default_exit_code(_kind), do: nil
end
