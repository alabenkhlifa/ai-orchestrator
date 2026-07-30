defmodule SddOrchestrator.Delivery.EvidencePresentation do
  @moduledoc """
  What one authorized reader is shown of a feature's verification evidence.

  This module reads; it records nothing and decides nothing. Every value it
  returns already exists on an immutable `Evidence` row or on the activity entry
  the completion gate wrote, so the screen cannot disagree with the record it is
  supposed to be showing. In particular, whether a screenshot applies is read
  from `ScreenshotEvidence.presentation/2` rather than derived a second time:
  two derivations of the same judgement are two answers waiting to differ.

  Three rules shape what comes out.

  Nothing is filtered. Superseded items and results that recorded an absence are
  returned exactly like a passing one, because a reader deciding whether to
  trust a completion claim has to see the proof that was replaced and the proof
  that never arrived. The one query that does drop superseded rows is the
  completion gate's, and it stays where it is.

  Every read re-checks participation. A person removed from the project between
  one render and the next is refused on the next call rather than served from
  what the screen already knows.

  No reference reaches the caller. An item reports *that* it has stored bytes
  and what they are; the bytes themselves come back only from
  `inline_artifact/4`, which goes through `ArtifactStore.fetch_for_evidence/4`
  and answers `{:error, :not_found}` identically for a stranger, another
  project's item, an unknown item, and an item that never had an artifact.
  """

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact

  alias SddOrchestrator.Delivery.{
    Activity,
    ActivityEntry,
    DeliveryStore,
    Evidence,
    ParticipantGuard,
    ScreenshotEvidence
  }

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()
  @type item :: map()
  @type verdict :: map()

  # The two entries the completion gate appends. A refusal is presented beside a
  # verified completion rather than instead of one, because "not verified" with
  # nothing behind it is the claim this whole path exists to replace.
  @verdict_types ~w(verification_completed verification_refused)

  # The stored types this screen can render as an image. A stored artifact of any
  # other type is described rather than shown, so nothing is ever handed to the
  # browser as something it is not.
  @inline_content_types ~w(image/png image/jpeg image/webp)

  # How much of an identifier is shown when the whole one is noise. The branch,
  # the commit, and the digest are shown in full: those are what a reader
  # actually checks the work against.
  @short_reference_length 8

  @doc "The evidence-carrying activity types the completion gate appends."
  @spec verdict_types() :: [String.t()]
  def verdict_types, do: @verdict_types

  @doc "The stored content types this presentation renders inline."
  @spec inline_content_types() :: [String.t()]
  def inline_content_types, do: @inline_content_types

  @doc """
  Lists one feature's evidence in authoritative order for a current participant.

  Order comes from the store rather than from this module, so the sequence a
  reader sees is the sequence the records were written in. Superseded items keep
  their original place instead of moving to the end.
  """
  @spec list(authority(), Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, [item()]} | {:error, :unauthorized}
  def list(authority, project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :read_evidence) do
      {:ok,
       Enum.map(feature_evidence(authority, project_id, feature_id), &present(authority, &1))}
    end
  end

  @doc """
  The completion gate's most recent conclusion about one feature, when there is one.

  A refusal carries the checks that failed, the checks that had no result, and
  the checks the environment could not run, so an incomplete verification stays
  legible instead of collapsing into a bare "not verified".
  """
  @spec verification(authority(), Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, verdict() | nil} | {:error, :unauthorized}
  def verification(authority, project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :read_evidence) do
      {:ok, latest_verdict(authority, project_id, feature_id)}
    end
  end

  @doc """
  Reads the bytes one item of evidence proves, for one acting person.

  The authorization seam is `ArtifactStore.fetch_for_evidence/4` and there is no
  second one. What comes back is content, not a location: an inline data value
  the screen embeds directly, so no addressable URL for private project bytes
  ever exists.
  """
  @spec inline_artifact(authority(), Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, map()} | {:error, :not_found}
  def inline_artifact(authority, project_id, evidence_id, actor) do
    with {:ok, %Artifact{} = artifact} <-
           ArtifactStore.fetch_for_evidence(authority, project_id, evidence_id, actor) do
      {:ok,
       %{
         evidence_id: evidence_id,
         content_type: artifact.content_type,
         byte_size: artifact.byte_size,
         redacted: artifact.redacted,
         digest: artifact.digest,
         inline?: inline?(artifact),
         data: data_value(artifact)
       }}
    end
  end

  @doc "The shortened form of one internal identifier, for display beside a name."
  @spec short_reference(String.t() | nil) :: String.t() | nil
  def short_reference(nil), do: nil

  def short_reference(id) when is_binary(id),
    do: id |> String.replace("-", "") |> String.slice(0, @short_reference_length)

  # `list_evidence` narrows by run, attempt, or commit rather than by feature,
  # because that is what the completion gate asks it. A feature's history spans
  # every run it has had, so the project's own ordered list is read and narrowed
  # here instead of stitching per-run pages back together in a different order.
  defp feature_evidence(authority, project_id, feature_id) do
    authority
    |> DeliveryStore.list_evidence(project_id)
    |> Enum.filter(&(&1.feature_id == feature_id))
  end

  defp present(authority, %Evidence{} = evidence) do
    screenshot = ScreenshotEvidence.presentation(authority, evidence)
    stored = stored_artifact(authority, evidence, screenshot)

    %{
      id: evidence.id,
      kind: evidence.kind,
      name: evidence.name,
      outcome: evidence.outcome,
      source: evidence.source,
      command: evidence.command,
      exit_code: evidence.exit_code,
      duration_ms: evidence.duration_ms,
      branch: evidence.branch,
      commit_sha: evidence.commit_sha,
      run_id: evidence.run_id,
      run_ref: short_reference(evidence.run_id),
      attempt_id: evidence.attempt_id,
      attempt_ref: short_reference(evidence.attempt_id),
      recorded_at: evidence.recorded_at,
      digest: evidence.digest,
      redacted: evidence.redacted,
      superseded?: not Evidence.current?(evidence),
      replaced_by_ref: short_reference(evidence.superseded_by_id),
      artifact_available?: stored.available?,
      content_type: stored.content_type,
      byte_size: stored.byte_size,
      capture_result: screenshot && screenshot.capture_result,
      capture_reason: screenshot && screenshot.reason
    }
  end

  # A screenshot's availability is whatever `ScreenshotEvidence` already decided.
  # Any other kind that named an artifact is looked up directly, because storage
  # is a fact about the store rather than a judgement about a capture.
  defp stored_artifact(_authority, _evidence, %{} = screenshot) do
    %{
      available?: screenshot.artifact_available?,
      content_type: screenshot.content_type,
      byte_size: screenshot.byte_size
    }
  end

  defp stored_artifact(authority, %Evidence{artifact_ref: ref} = evidence, nil)
       when is_binary(ref) do
    case ArtifactStore.stat(authority, evidence.project_id, ref) do
      {:ok, %Artifact{} = artifact} ->
        %{available?: true, content_type: artifact.content_type, byte_size: artifact.byte_size}

      {:error, :not_found} ->
        absent_artifact()
    end
  end

  defp stored_artifact(_authority, _evidence, nil), do: absent_artifact()

  defp absent_artifact, do: %{available?: false, content_type: nil, byte_size: nil}

  defp latest_verdict(authority, project_id, feature_id) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: Activity.max_limit())
    |> Enum.filter(&(&1.type in @verdict_types))
    |> List.last()
    |> case do
      nil -> nil
      %ActivityEntry{} = entry -> verdict_summary(entry)
    end
  end

  defp verdict_summary(%ActivityEntry{payload: payload} = entry) do
    %{
      verified?: entry.type == "verification_completed",
      reason: payload["reason"],
      branch: payload["branch"],
      commit_sha: payload["commit_sha"],
      attempt_number: payload["attempt_number"],
      required_count: payload["required_count"] || 0,
      passed_count: payload["passed_count"] || 0,
      failed: names(payload["failed"]),
      missing: names(payload["missing"]),
      unsupported: names(payload["unsupported"]),
      screenshot_failed: names(payload["screenshot_failed"]),
      occurred_at: entry.occurred_at
    }
  end

  defp names(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp names(_absent), do: []

  defp inline?(%Artifact{content_type: type, content: content}),
    do: type in @inline_content_types and is_binary(content)

  defp data_value(%Artifact{content_type: type, content: content} = artifact) do
    if inline?(artifact), do: "data:#{type};base64,#{Base.encode64(content)}", else: nil
  end
end
