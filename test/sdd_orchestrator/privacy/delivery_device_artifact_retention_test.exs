defmodule SddOrchestrator.Privacy.DeliveryDeviceArtifactRetentionTest do
  @moduledoc """
  Task 10 proof: device-authoritative superseded evidence artifacts lose their
  stored bytes.

  The device half of the lifecycle Task 2 proved for the hosted store, on the
  same 30-day window and with the same end state: the screenshot or log a
  superseded item captured is released, while the record itself is left exactly
  as it was. `superseded_by_id`, `artifact_ref`, `digest`, and `recorded_at` are
  the provenance a reader follows, and the intended result is a record that
  still names a reference whose content is gone.

  Three things make the device half its own proof rather than a repeat. The
  decision is made entirely inside the device authority — a device project has
  no hosted row at all, and this sweep must never create one. The supersession
  instant is the *replacement* record's `recorded_at` rather than a
  server-written `inserted_at`, because `Evidence.to_value/1` emits no Ecto
  timestamp at all and on a device the worker is the authority for when its own
  result happened. And an unreachable worker is a pause, not a failure: this
  rule reports zero and the rest of the pass still runs.

  The failure this file exists to prevent is the same one Task 2 guards, and it
  is worse than retaining bytes too long: artifacts are digest-addressed, so one
  stored object can be named by several records, and releasing content on the
  strength of the expired record alone would destroy proof that is still
  current.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{ArtifactStore, Evidence, EvidenceArtifact}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.Retention
  alias SddOrchestrator.Projects.Project

  @day 24 * 60 * 60
  @window 30 * @day
  @commit "a1b2c3d4e5f6a7b8c9d0"

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "device-artifact-retention-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device artifact retention project",
        repository_fingerprint:
          "device-artifact-retention-fingerprint-#{System.unique_integer([:positive])}",
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    %{
      project: project,
      workspace: workspace,
      # The same authority the rule builds for this project, from the project's
      # own `workspace_id`.
      authority: %DeviceWorkspace{id: project.workspace_id},
      feature_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      branch: "sdd/device-feature-#{System.unique_integer([:positive])}"
    }
  end

  describe "device superseded artifact expiry" do
    test "releases the bytes of an item superseded 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = superseded_pair(context, "due", DateTime.add(now, -@window, :second))

      just_inside =
        superseded_pair(context, "just-inside", DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, due.superseded.ref)
      assert present?(context, just_inside.superseded.ref)
    end

    test "keeps the bytes of a record that was never superseded, however old", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      current = stored_evidence(context, "never-superseded", recorded_at: long_ago)

      assert %{expired_device_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, current.ref)
    end

    test "keeps the replacement's own bytes when it releases the item it replaced", context do
      now = truncated_now()

      pair = superseded_pair(context, "rerun", DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, pair.superseded.ref)
      assert present?(context, pair.replacement.ref)
    end
  end

  describe "digest-addressed sharing" do
    # The case that protects accepted evidence. Two records with byte-identical
    # content are one stored artifact, so the long-superseded record's reference
    # is also the current record's reference. Releasing it would silently
    # destroy proof that is still current.
    test "keeps bytes a current record still names when a superseded record shares its digest",
         context do
      now = truncated_now()

      current = stored_evidence(context, "shared")

      shared_superseded =
        superseded_pair(context, "shared", DateTime.add(now, -10 * @window, :second))

      assert shared_superseded.superseded.ref == current.ref

      assert %{expired_device_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, current.ref)

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, current.ref)

      assert artifact.content == current.content
    end

    # The other direction: the shared-digest guard must not become a rule that
    # nothing is ever released. Once every record naming the content has
    # finished with it, the one stored object goes, and it is counted once.
    test "releases one shared artifact once both records naming it have expired", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      first = superseded_pair(context, "twice", long_ago)
      second = superseded_pair(context, "twice", long_ago)

      assert first.superseded.ref == second.superseded.ref
      refute first.superseded.evidence.id == second.superseded.evidence.id

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, first.superseded.ref)
    end

    test "keeps bytes a more recently superseded record still names", context do
      now = truncated_now()

      old = superseded_pair(context, "staggered", DateTime.add(now, -10 * @window, :second))
      recent = superseded_pair(context, "staggered", DateTime.add(now, -@window + 1, :second))

      assert old.superseded.ref == recent.superseded.ref

      assert %{expired_device_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, old.superseded.ref)
    end
  end

  describe "immutable provenance" do
    test "rewrites nothing on the superseded record or its replacement", context do
      now = truncated_now()

      pair = superseded_pair(context, "provenance", DateTime.add(now, -@window, :second))

      before_superseded = stored_value(context, pair.superseded.evidence.id)
      before_replacement = stored_value(context, pair.replacement.evidence.id)

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      # Whole-value equality of what the device store holds under each key: this
      # rule issues no put against `:evidence` at all, so not one field of
      # either record — and no tombstone — may appear.
      assert stored_value(context, pair.superseded.evidence.id) == before_superseded
      assert stored_value(context, pair.replacement.evidence.id) == before_replacement
    end

    test "reports the artifact as unavailable while the record and its digest still read",
         context do
      now = truncated_now()

      pair = superseded_pair(context, "seam", DateTime.add(now, -@window, :second))
      ref = pair.superseded.ref

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      # Unavailable, not a raise and not a partial record.
      assert {:error, :not_found} =
               ArtifactStore.fetch(context.authority, context.project.id, ref)

      assert {:error, :not_found} = ArtifactStore.stat(context.authority, context.project.id, ref)

      # The record still decodes, still names the reference, and still says what
      # the content was.
      assert {:ok, record} =
               context |> stored_value(pair.superseded.evidence.id) |> Evidence.from_value()

      assert record.artifact_ref == ref
      assert {:ok, record.digest} == ArtifactStore.digest_from_ref(ref)
      assert record.digest == pair.superseded.digest
      assert record.superseded_by_id == pair.replacement.evidence.id
      assert DateTime.compare(record.recorded_at, pair.superseded.evidence.recorded_at) == :eq
    end
  end

  describe "device authority isolation" do
    test "decides eligibility inside the device authority, creating no hosted copy", context do
      now = truncated_now()

      # The authority the rule builds is the device workspace this project was
      # registered under, not a hosted one.
      assert context.project.workspace_id == context.workspace.id

      pair = superseded_pair(context, "isolated", DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, pair.superseded.ref)

      # Nothing about this project was read from or written to the hosted store
      # to decide what to prune, so after a full sweep the hosted tables the
      # hosted half governs are still empty — including the project row itself,
      # which a device-authoritative project never has.
      assert Repo.aggregate(Evidence, :count) == 0
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
      assert Repo.aggregate(Project, :count) == 0
    end
  end

  describe "availability and idempotency" do
    test "an unreachable device store pauses only its own rule", context do
      now = truncated_now()

      superseded_pair(context, "paused", DateTime.add(now, -@window, :second))

      hosted = hosted_due_artifact!(now)

      stop_supervised!(Local)

      # The device rule reports zero rather than raising, and the pass carries
      # on: the hosted half of the very same lifecycle still releases its own
      # due bytes in the same call.
      assert %{expired_device_delivery_artifacts: 0, expired_delivery_artifacts: 1} =
               Retention.prune_all(now)

      assert ArtifactStore.fetch(hosted.authority, hosted.project_id, hosted.ref) ==
               {:error, :not_found}
    end

    test "a second pass immediately after reports nothing left to remove", context do
      now = truncated_now()

      superseded_pair(context, "repeat-a", DateTime.add(now, -@window, :second))
      superseded_pair(context, "repeat-b", DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_artifacts: 2} = Retention.prune_all(now)
      assert %{expired_device_delivery_artifacts: 0} = Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # One superseded item of proof and the rerun that replaced it, each with its
  # own stored bytes. The replacement's `recorded_at` is the supersession
  # instant: it is the only instant the device value shape carries, and on a
  # device the worker that recorded the replacement is the authority for when
  # its own result happened.
  defp superseded_pair(context, seed, superseded_at) do
    replacement = stored_evidence(context, seed <> "-replacement", recorded_at: superseded_at)

    superseded =
      stored_evidence(context, seed,
        superseded_by_id: replacement.evidence.id,
        recorded_at: DateTime.add(superseded_at, -@day, :second)
      )

    %{superseded: superseded, replacement: replacement}
  end

  # Stores real bytes through the project's own device authority and records one
  # item of evidence naming them. The same seed produces byte-identical content,
  # so two records built from one seed genuinely share a single stored artifact
  # rather than merely looking as though they do.
  defp stored_evidence(context, seed, attrs \\ []) do
    content = DeliveryFixtures.png_bytes(seed)
    digest = DeliveryFixtures.content_digest(content)

    ref =
      DeliveryFixtures.artifact_fixture(context.authority, context.project.id, content: content)

    evidence =
      put_evidence!(context, Map.merge(Map.new(attrs), %{digest: digest, artifact_ref: ref}))

    %{evidence: evidence, ref: ref, digest: digest, content: content}
  end

  # Written straight through the delivery seam rather than through the delivery
  # store's own ingestion, because that writes its instants from the live clock
  # and this rule is measured against them. `Evidence.to_value/1` renders
  # `recorded_at` as an ISO8601 string, which is the only instant that survives
  # the device seam at all.
  defp put_evidence!(context, attrs) do
    superseded_by_id = Map.get(attrs, :superseded_by_id)

    evidence = %Evidence{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature_id,
      run_id: context.run_id,
      command_id: "cmd-#{System.unique_integer([:positive])}",
      kind: "screenshot",
      name: Map.get(attrs, :name, "checkout screen"),
      outcome: Map.get(attrs, :outcome, "passed"),
      duration_ms: 12,
      branch: context.branch,
      commit_sha: @commit,
      source: "worker",
      recorded_at: Map.get(attrs, :recorded_at, truncated_now()),
      digest: Map.fetch!(attrs, :digest),
      redacted: false,
      artifact_ref: Map.fetch!(attrs, :artifact_ref),
      superseded_by_id: superseded_by_id,
      state_version: if(is_nil(superseded_by_id), do: 1, else: 2)
    }

    {:ok, _applied} =
      Devices.commit_delivery(context.project.id, [
        {:put, :evidence, evidence.id, Evidence.to_value(evidence), nil}
      ])

    evidence
  end

  defp stored_value(context, evidence_id) do
    {:ok, value} = Devices.get_delivery(context.project.id, :evidence, evidence_id)
    value
  end

  defp present?(context, ref),
    do: match?({:ok, _artifact}, ArtifactStore.fetch(context.authority, context.project.id, ref))

  defp absent?(context, ref),
    do: ArtifactStore.fetch(context.authority, context.project.id, ref) == {:error, :not_found}

  # One hosted superseded item whose bytes Task 2's rule is due to release, so
  # the unreachable-device proof can show the pass continuing rather than only
  # that it did not raise. Nothing here touches the device store.
  defp hosted_due_artifact!(now) do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)
    run = DeliveryFixtures.run_fixture(hosted.project, feature)
    at = DateTime.add(now, -@window, :second)

    context = %{
      authority: hosted.workspace,
      project_id: hosted.project.id,
      feature_id: feature.id,
      run_id: run.id,
      branch: run.branch
    }

    replacement = insert_hosted_evidence!(context, "hosted-replacement", at, nil)

    superseded =
      insert_hosted_evidence!(context, "hosted", DateTime.add(at, -@day, :second), replacement.id)

    Map.put(context, :ref, superseded.artifact_ref)
  end

  defp insert_hosted_evidence!(context, seed, at, superseded_by_id) do
    content = DeliveryFixtures.png_bytes(seed)

    ref =
      DeliveryFixtures.artifact_fixture(context.authority, context.project_id, content: content)

    Repo.insert!(%Evidence{
      id: Ecto.UUID.generate(),
      project_id: context.project_id,
      feature_id: context.feature_id,
      run_id: context.run_id,
      command_id: "cmd-#{System.unique_integer([:positive])}",
      kind: "screenshot",
      name: "checkout screen",
      outcome: "passed",
      duration_ms: 12,
      branch: context.branch,
      commit_sha: @commit,
      source: "worker",
      recorded_at: usec(at),
      digest: DeliveryFixtures.content_digest(content),
      redacted: false,
      artifact_ref: ref,
      superseded_by_id: superseded_by_id,
      state_version: if(is_nil(superseded_by_id), do: 1, else: 2),
      # The hosted rule measures the replacement's server-written `inserted_at`,
      # which `evidence` declares as `:utc_datetime`.
      inserted_at: DateTime.truncate(at, :second)
    })
  end

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision the hosted
  # `recorded_at` column declares. Adding zero microseconds does.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)
end
