defmodule SddOrchestrator.DeliveryFixtures do
  @moduledoc "Test fixtures for feature delivery."

  alias SddOrchestrator.Delivery.{
    Activity,
    AgentRun,
    ArtifactStore,
    EvidenceIngestion,
    Feature,
    RunAttempt,
    VerificationCompletion,
    WorkerProtocol
  }

  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  # One real 1x1 PNG. Small enough to keep tests fast, and genuinely a PNG so a
  # content-type check is proven against the type it actually claims.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  @doc """
  Creates one hosted project with an owner profile and one active participant.

  Returns the project together with the actor maps both members use for
  authorization.
  """
  def delivery_project_fixture do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Member")
    })

    Map.merge(result, %{
      identity: identity,
      owner_actor: %{account_id: result.account.id, hosted_identity_id: nil},
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end

  @doc "Creates one feature in `Draft`."
  def feature_fixture(project, creator_account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %Feature{}
    |> Feature.create_changeset(%{
      project_id: project.id,
      title: Map.get(attrs, :title, unique_title()),
      creator_account_id: creator_account.id,
      assigned_account_id: Map.get(attrs, :assigned_account_id)
    })
    |> Repo.insert!()
  end

  def unique_title(prefix \\ "Feature"),
    do: "#{prefix} #{System.unique_integer([:positive])}"

  @doc "Creates one run in `pending` for a feature, on its own isolated branch."
  def run_fixture(project, feature, attrs \\ %{}) do
    project |> run_changeset(feature, attrs) |> Repo.insert!()
  end

  @doc "The same run changeset, for proving a constraint without raising."
  def run_changeset(project, feature, attrs \\ %{}) do
    attrs = Map.new(attrs)
    unique = System.unique_integer([:positive])

    AgentRun.create_changeset(%AgentRun{}, %{
      project_id: project.id,
      feature_id: feature.id,
      initiator_account_id: Map.get(attrs, :initiator_account_id),
      starting_revision_id: Map.get(attrs, :starting_revision_id, "rev-#{unique}"),
      starting_revision_digest:
        Map.get(attrs, :starting_revision_digest, digest("rev-#{unique}")),
      approved_slice: Map.get(attrs, :approved_slice, "slice-07"),
      branch: Map.get(attrs, :branch, "sdd/feature-#{unique}")
    })
  end

  @doc "Creates one ordered attempt of a run."
  def attempt_fixture(run, attrs \\ %{}) do
    run |> attempt_changeset(attrs) |> Repo.insert!()
  end

  @doc "The same attempt changeset, for proving a constraint without raising."
  def attempt_changeset(run, attrs \\ %{}) do
    attrs = Map.new(attrs)
    number = Map.get(attrs, :attempt_number, run.current_attempt_number + 1)

    RunAttempt.create_changeset(%RunAttempt{}, %{
      run_id: run.id,
      attempt_number: number,
      continuation_reason: Map.get(attrs, :continuation_reason, "initial"),
      effective_revision_id: Map.get(attrs, :effective_revision_id, run.effective_revision_id),
      effective_revision_digest:
        Map.get(attrs, :effective_revision_digest, run.effective_revision_digest),
      manifest_digest: Map.get(attrs, :manifest_digest, digest("manifest-#{run.id}-#{number}")),
      required_checks: Map.get(attrs, :required_checks, []),
      fence_token: Map.get(attrs, :fence_token, number)
    })
  end

  @doc """
  The required-check contract an attempt snapshots from its manifest.

  Names are what the completion gate looks evidence up by, so a fixture that
  invented its own shape would prove nothing about the manifest it stands in for.
  """
  def required_check_contract(names) do
    Enum.map(names, &%{"name" => &1, "command" => &1})
  end

  @doc """
  Creates one run together with the current attempt a worker would be executing.

  Almost every worker-initiated path needs both, and needs them consistent: the
  attempt is the run's current one and carries the fence the worker must present.
  """
  def run_with_attempt_fixture(project, feature, attrs \\ %{}) do
    run = run_fixture(project, feature, attrs)
    %{run: run, attempt: attempt_fixture(run, attrs)}
  end

  @doc """
  The metadata one worker artifact upload declares for an attempt.

  The digest describes the content rather than being chosen, so a test that
  wants a mismatch has to say so explicitly instead of getting one by accident.
  """
  def artifact_upload_params(run, attempt, attrs \\ %{}) do
    attrs = Map.new(attrs)
    content = Map.get(attrs, :content, png_bytes())

    %{
      "run_id" => Map.get(attrs, :run_id, run.id),
      "attempt_id" => Map.get(attrs, :attempt_id, attempt.id),
      "fence" => to_string(Map.get(attrs, :fence, attempt.fence_token)),
      "digest" => Map.get(attrs, :digest, content_digest(content)),
      "content_type" => Map.get(attrs, :content_type, "image/png"),
      "redacted" => to_string(Map.get(attrs, :redacted, false))
    }
  end

  @doc "Appends one ordered activity entry to a feature."
  def activity_fixture(project, feature, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, entry} =
      Activity.append(
        Map.merge(
          %{
            project_id: project.id,
            feature_id: feature.id,
            actor_kind: "system",
            type: "progress",
            payload: %{"step" => "fixture"}
          },
          attrs
        )
      )

    entry
  end

  @doc "A deterministic 64-character hex digest for fixture references."
  def digest(seed), do: :sha256 |> :crypto.hash(seed) |> Base.encode16(case: :lower)

  @doc "One real 1x1 PNG, made distinct by trailing bytes when a suffix is given."
  def png_bytes(suffix \\ "")
  def png_bytes(""), do: @png
  def png_bytes(suffix), do: @png <> suffix

  @doc """
  Builds one valid artifact for the private store, digest included.

  The digest is computed from the content rather than supplied, because a
  fixture that declared its own would prove nothing about the store's check.
  """
  def artifact_attrs(attrs \\ %{}) do
    attrs = Map.new(attrs)
    content = Map.get(attrs, :content, png_bytes())

    %{
      content: content,
      content_type: Map.get(attrs, :content_type, "image/png"),
      digest: Map.get(attrs, :digest, content_digest(content)),
      redacted: Map.get(attrs, :redacted, false)
    }
  end

  @doc "Stores one artifact through the project's own authority and returns its reference."
  def artifact_fixture(authority, project_id, attrs \\ %{}) do
    {:ok, ref} = ArtifactStore.put(authority, project_id, artifact_attrs(attrs))
    ref
  end

  @doc "The digest the store will recompute for this exact content."
  def content_digest(content),
    do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  @doc """
  Records a genuine verified completion for one attempt on one exact commit.

  Everything downstream of verification — a preview above all — must start from
  what the completion gate actually recorded rather than from a hand-written
  activity row, or the test proves the fixture instead of the behaviour. Every
  check the attempt's own contract names is passed against `commit_sha` and the
  worker's completion event is ingested exactly as a real worker would send it.

  `checks: :skip` records no evidence, which is how a caller gets a genuine
  *refused* completion rather than a verified one it then has to pretend about.
  """
  def verified_completion_fixture(authority, project, run, attempt, attrs \\ %{}) do
    attrs = Map.new(attrs)
    commit = Map.get(attrs, :commit_sha, "a1b2c3d4e5f6a7b8c9d0")
    contract = passed_checks(attempt, attrs)

    contract
    |> Enum.with_index(1)
    |> Enum.each(fn {name, index} ->
      {:ok, _recorded} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          check_event(run, attempt, name, commit, index)
        )
    end)

    {:ok, results} =
      VerificationCompletion.ingest(
        authority,
        project.id,
        completion_event(run, attempt, commit, length(contract) + 1)
      )

    Map.put(results, :commit_sha, commit)
  end

  defp passed_checks(_attempt, %{checks: :skip}), do: []

  defp passed_checks(attempt, _attrs),
    do: Enum.map(attempt.required_checks || [], &Map.get(&1, "name"))

  defp check_event(run, attempt, name, commit, sequence) do
    worker_event(run, attempt, sequence, "evidence", "check", %{
      "kind" => "required_check",
      "name" => name,
      "outcome" => "passed",
      "command" => name,
      "exit_code" => 0,
      "duration_ms" => 1_000,
      "commit_sha" => commit,
      "digest" => digest(name),
      "redacted" => false
    })
  end

  defp completion_event(run, attempt, commit, sequence) do
    worker_event(run, attempt, sequence, "verification_completed", "worker", %{
      "branch" => run.branch,
      "revision_id" => attempt.effective_revision_id,
      "commit_sha" => commit
    })
  end

  defp worker_event(run, attempt, sequence, event_type, source, payload) do
    unique = System.unique_integer([:positive])

    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{unique}",
      "run_id" => run.id,
      "command_id" => "cmd-#{unique}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => sequence,
      "event_type" => event_type,
      "source" => source,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => payload
    }
  end
end
