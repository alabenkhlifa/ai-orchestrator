defmodule SddOrchestrator.Privacy.DeliveryArtifactRetentionTest do
  @moduledoc """
  Task 2 proof: superseded evidence artifacts lose their stored bytes.

  An item of evidence that a later result replaced stops proving anything. The
  screenshot or log it captured is released 30 days after that supersession,
  while the row itself is left exactly as it was: `superseded_by_id`,
  `artifact_ref`, `digest`, and `recorded_at` are the provenance a reader
  follows, the database refuses to rewrite them, and the intended end state is
  a row that still names a reference whose content is gone.

  The supersession instant is the *replacement* row's `inserted_at`. `evidence`
  deliberately has no `updated_at` and no `superseded_at` — see its create
  migration and the `evidence_reject_rewrite` trigger — and the replacement is
  inserted in the same atomic commit as the supersession link, so its
  server-written timestamp is exactly when the older result stopped being
  current.

  The failure this file exists to prevent is destroying accepted evidence.
  Artifacts are digest-addressed, so one stored object can be named by several
  rows; a rerun that produced byte-identical output, or a current row and a
  superseded row describing the same capture, all point at one artifact.
  Releasing content on the strength of the expired row alone would take the
  bytes out from under every other row naming them.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ArtifactStore, Evidence}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Privacy.Retention

  @day 24 * 60 * 60
  @window 30 * @day

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)
    run = DeliveryFixtures.run_fixture(context.project, feature)

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      run: run
    }
  end

  describe "superseded artifact expiry" do
    test "releases the bytes of an item superseded 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = superseded_pair(context, "due", DateTime.add(now, -@window, :second))

      just_inside =
        superseded_pair(context, "just-inside", DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, due.superseded.ref)
      assert present?(context, just_inside.superseded.ref)
    end

    test "keeps the bytes of a current item however old the capture is", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      current = stored_evidence(context, "current", inserted_at: long_ago, recorded_at: long_ago)

      assert %{expired_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, current.ref)
    end

    test "keeps the replacement's own bytes when it releases the item it replaced", context do
      now = truncated_now()

      pair = superseded_pair(context, "rerun", DateTime.add(now, -@window, :second))

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, pair.superseded.ref)
      assert present?(context, pair.replacement.ref)
    end

    test "leaves accepted evidence and its bytes untouched while an unrelated item expires",
         context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      accepted =
        stored_evidence(context, "accepted",
          outcome: "passed",
          inserted_at: long_ago,
          recorded_at: long_ago
        )

      _expired = superseded_pair(context, "unrelated", DateTime.add(now, -@window, :second))

      before_accepted = Repo.get(Evidence, accepted.evidence.id)

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      assert present?(context, accepted.ref)
      assert Repo.get(Evidence, accepted.evidence.id) == before_accepted

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, accepted.ref)

      assert artifact.content == accepted.content
      assert artifact.digest == accepted.evidence.digest
    end
  end

  describe "digest-addressed sharing" do
    # The case that protects accepted evidence. Two items with byte-identical
    # content are one stored artifact, so the expired item's reference is also
    # the current item's reference. Releasing it would silently destroy proof
    # that is still current.
    test "keeps bytes a current item still names when a superseded item shares its digest",
         context do
      now = truncated_now()

      current = stored_evidence(context, "shared")

      shared_superseded =
        superseded_pair(context, "shared", DateTime.add(now, -10 * @window, :second))

      assert shared_superseded.superseded.ref == current.ref

      assert %{expired_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, current.ref)

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, current.ref)

      assert artifact.content == current.content
    end

    # The other direction: the shared-digest guard must not become a rule that
    # nothing is ever released. Once every row naming the content has finished
    # with it, the one stored object goes, and it is counted once.
    test "releases one shared artifact once both items naming it have expired", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      first = superseded_pair(context, "twice", long_ago)
      second = superseded_pair(context, "twice", long_ago)

      assert first.superseded.ref == second.superseded.ref
      refute first.superseded.evidence.id == second.superseded.evidence.id

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      assert absent?(context, first.superseded.ref)
    end

    test "keeps bytes a more recently superseded item still names", context do
      now = truncated_now()

      old = superseded_pair(context, "staggered", DateTime.add(now, -10 * @window, :second))
      recent = superseded_pair(context, "staggered", DateTime.add(now, -@window + 1, :second))

      assert old.superseded.ref == recent.superseded.ref

      assert %{expired_delivery_artifacts: 0} = Retention.prune_all(now)

      assert present?(context, old.superseded.ref)
    end
  end

  describe "immutable provenance" do
    test "rewrites nothing on the superseded row or its replacement", context do
      now = truncated_now()

      pair = superseded_pair(context, "provenance", DateTime.add(now, -@window, :second))

      before_superseded = Repo.get(Evidence, pair.superseded.evidence.id)
      before_replacement = Repo.get(Evidence, pair.replacement.evidence.id)

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      # Full-struct equality, which also proves the `evidence_no_rewrite`
      # trigger was never provoked: any update at all would have raised rather
      # than produced a differing row.
      assert Repo.get(Evidence, pair.superseded.evidence.id) == before_superseded
      assert Repo.get(Evidence, pair.replacement.evidence.id) == before_replacement
    end

    test "reports the artifact as unavailable while the row and its digest still read", context do
      now = truncated_now()

      pair = superseded_pair(context, "seam", DateTime.add(now, -@window, :second))
      ref = pair.superseded.ref

      assert %{expired_delivery_artifacts: 1} = Retention.prune_all(now)

      # Unavailable, not a raise and not a partial record.
      assert {:error, :not_found} =
               ArtifactStore.fetch(context.authority, context.project.id, ref)

      assert {:error, :not_found} = ArtifactStore.stat(context.authority, context.project.id, ref)

      # The row still names it, and still says what the content was.
      row = Repo.get(Evidence, pair.superseded.evidence.id)
      assert row.artifact_ref == ref
      assert {:ok, row.digest} == ArtifactStore.digest_from_ref(ref)
      assert row.digest == pair.superseded.digest
      assert row.superseded_by_id == pair.replacement.evidence.id
      assert row.recorded_at == pair.superseded.evidence.recorded_at
    end
  end

  describe "idempotency" do
    test "a second pass immediately after reports nothing left to remove", context do
      now = truncated_now()

      superseded_pair(context, "repeat-a", DateTime.add(now, -@window, :second))
      superseded_pair(context, "repeat-b", DateTime.add(now, -@window, :second))

      assert %{expired_delivery_artifacts: 2} = Retention.prune_all(now)
      assert %{expired_delivery_artifacts: 0} = Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # One superseded item of proof and the rerun that replaced it, each with its
  # own stored bytes. The replacement is written first because the superseded
  # row's foreign key names it, and its `inserted_at` is the supersession
  # instant: real ingestion writes the replacement and the supersession link in
  # one atomic commit.
  defp superseded_pair(context, seed, superseded_at) do
    replacement =
      stored_evidence(context, seed <> "-replacement",
        inserted_at: superseded_at,
        recorded_at: superseded_at
      )

    superseded =
      stored_evidence(context, seed,
        superseded_by_id: replacement.evidence.id,
        inserted_at: DateTime.add(superseded_at, -@day, :second),
        recorded_at: DateTime.add(superseded_at, -@day, :second)
      )

    %{superseded: superseded, replacement: replacement}
  end

  # Stores real bytes through the project's own authority and records one item
  # of evidence naming them. The same seed produces byte-identical content, so
  # two items built from one seed genuinely share a single stored artifact
  # rather than merely looking as though they do.
  defp stored_evidence(context, seed, attrs \\ []) do
    content = DeliveryFixtures.png_bytes(seed)
    digest = DeliveryFixtures.content_digest(content)

    ref =
      DeliveryFixtures.artifact_fixture(context.authority, context.project.id, content: content)

    evidence =
      insert_evidence(context, Map.merge(Map.new(attrs), %{digest: digest, artifact_ref: ref}))

    %{evidence: evidence, ref: ref, digest: digest, content: content}
  end

  # Inserted directly rather than through `EvidenceIngestion`, because the rule
  # is measured against `inserted_at`, which real ingestion always writes from
  # the live clock. Inserting is the only write available anyway: the
  # `evidence_no_rewrite` trigger would refuse to backdate a stored row.
  defp insert_evidence(context, attrs) do
    recorded_at = attrs |> Map.get(:recorded_at, DateTime.utc_now()) |> usec()
    inserted_at = attrs |> Map.get(:inserted_at, recorded_at) |> DateTime.truncate(:second)
    superseded_by_id = Map.get(attrs, :superseded_by_id)

    Repo.insert!(%Evidence{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature.id,
      run_id: context.run.id,
      command_id: "cmd-#{System.unique_integer([:positive])}",
      kind: "screenshot",
      name: Map.get(attrs, :name, "checkout screen"),
      outcome: Map.get(attrs, :outcome, "passed"),
      duration_ms: 12,
      branch: context.run.branch,
      commit_sha: "a1b2c3d4e5f6a7b8c9d0",
      source: "worker",
      recorded_at: recorded_at,
      digest: Map.fetch!(attrs, :digest),
      redacted: false,
      artifact_ref: Map.fetch!(attrs, :artifact_ref),
      superseded_by_id: superseded_by_id,
      state_version: if(is_nil(superseded_by_id), do: 1, else: 2),
      inserted_at: inserted_at
    })
  end

  defp present?(context, ref),
    do: match?({:ok, _artifact}, ArtifactStore.fetch(context.authority, context.project.id, ref))

  defp absent?(context, ref),
    do: ArtifactStore.fetch(context.authority, context.project.id, ref) == {:error, :not_found}

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision `recorded_at`
  # declares. Adding zero microseconds does.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)
end
