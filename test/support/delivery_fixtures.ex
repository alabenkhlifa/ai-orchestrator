defmodule SddOrchestrator.DeliveryFixtures do
  @moduledoc "Test fixtures for feature delivery."

  alias SddOrchestrator.Delivery.{Activity, AgentRun, ArtifactStore, Feature, RunAttempt}
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
      fence_token: Map.get(attrs, :fence_token, number)
    })
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
end
