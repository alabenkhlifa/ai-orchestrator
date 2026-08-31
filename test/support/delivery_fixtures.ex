defmodule SddOrchestrator.DeliveryFixtures do
  @moduledoc "Test fixtures for feature delivery."

  alias SddOrchestrator.Delivery.{
    Activity,
    AgentRun,
    ArtifactStore,
    EvidenceIngestion,
    ExecutionManifest,
    Features,
    GuidedRequirements,
    ParticipantGuard,
    RunAttempt,
    VerificationCompletion,
    WorkerProtocol
  }

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    PackageSection,
    ProjectPackage,
    RestoreDecision
  }

  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  # One real 1x1 PNG. Small enough to keep tests fast, and genuinely a PNG so a
  # content-type check is proven against the type it actually claims.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  @repository_provider "github"
  @scanner_contract_digest String.duplicate("a", 64)
  @assessment_disclosure_digest String.duplicate("b", 64)

  # The commit the seeded assessment is bound to, and so the base revision every
  # manifest built from the approved profile carries.
  @base_revision String.duplicate("1", 40)

  # The approved profile's own values. One command, and the scope entries
  # together, weigh more than `ProtocolLimits.max_reference_bytes`, so every
  # manifest a test builds proves that a real profile's lists travel in fields
  # of their own rather than squeezed into `agent_ref` or `worker_ref`.
  @long_command "mix test " <> String.duplicate("--include slow_case ", 30)

  @deep_directories Enum.map(1..6, fn index ->
                      "lib/" <> String.duplicate("deep_module_#{index}_", 6) <> "leaf"
                    end)

  @profile_fields %{
    commands: ["mix test", @long_command],
    required_checks: ["mix test"],
    allowed_scope: @deep_directories,
    gaps: [],
    conflicts: [],
    multi_root_blockers: []
  }

  # One body per guided part, for a feature a test needs readiness to clear.
  # The words are deliberately dull: a test that reads them is proving the
  # document round-tripped, never what it says.
  @filled_requirements %{
    "outcome" => "A person can do the thing this feature exists for.",
    "users" => "The project's owner and the participants invited to it.",
    "rules" => "Nothing starts until the person confirms it.",
    "done" => "The person walks the path once and sees the result."
  }

  @assessment_findings [
    %{
      category: "instruction",
      path: "AGENTS.md",
      bytes: 12,
      sha256: String.duplicate("d", 64),
      line_count: 3
    }
  ]

  @doc """
  Creates one hosted project with an owner profile and one active participant.

  The repository is connected and one execution profile is approved, because
  that is the state a project has to be in before any run may start or
  continue: every manifest reads its base revision, checks, root, commands, and
  scope from the approved profile, and there is no configured fallback.

  Returns the project together with the actor maps both members use for
  authorization.
  """
  def delivery_project_fixture do
    result = ParticipationFixtures.hosted_project_fixture()
    project = connect_repository!(result.project)

    ParticipationFixtures.member_profile_fixture(project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Member")
    })

    Map.merge(result, %{
      project: project,
      profile: approve_profile!(result.account.id, project),
      identity: identity,
      owner_actor: %{account_id: result.account.id, hosted_identity_id: nil},
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end

  @doc "The base revision the seeded profile, and so every manifest, is anchored to."
  def base_revision, do: @base_revision

  @doc "The proposal fields the seeded profile is approved from."
  def profile_fields, do: @profile_fields

  @doc """
  Connects one hosted repository to a project.

  Both the assessment store and the profile store refuse a project whose
  repository binding is not connected, so nothing may be approved for a project
  without this.
  """
  def connect_repository!(project) do
    repository_id = System.unique_integer([:positive])

    project =
      project
      |> Ecto.Changeset.change(%{
        storage_mode: "hosted",
        lifecycle_state: "active",
        repository_provider: @repository_provider,
        canonical_repository_id: Integer.to_string(repository_id)
      })
      |> Repo.update!()

    %RepositoryConnection{}
    |> RepositoryConnection.create_changeset(%{
      project_id: project.id,
      workspace_id: project.workspace_id,
      provider: @repository_provider,
      provider_repository_id: repository_id,
      state: "connected"
    })
    |> Repo.insert!()

    project
  end

  @doc """
  Approves one execution profile by walking the real assessment path.

  The profile a manifest reads is therefore one an owner could actually have
  approved rather than a row. Approval is append-only, so a second call adds a
  higher version instead of replacing the first.
  """
  def approve_profile!(authority_or_account_id, project, opts \\ [])

  def approve_profile!({:device, %DeviceWorkspace{}} = authority, project, opts),
    do: approve_through_domain!(authority, project, opts)

  def approve_profile!(account_id, project, opts) when is_binary(account_id),
    do: approve_through_domain!({:hosted, account_id}, project, opts)

  @doc """
  Approves one execution profile on this device for a project the device owns.

  A device-authoritative project keeps its own profiles, so a run continued
  under a device authority reads them from the device store. The project is
  restored onto the device through the portability path, which is the only
  supported way it comes to exist there holding the same stable id the hosted
  records already use.
  """
  def approve_device_profile!(%DeviceWorkspace{} = workspace, project, opts \\ []) do
    _worker = detected_worker!(workspace)
    device_project = restore_onto_device!(workspace, project)

    {:ok, connected} =
      Devices.connect_repository(
        device_project.id,
        device_project.repository_provider,
        device_project.repository_id
      )

    approve_profile!({:device, workspace}, connected, opts)
  end

  # A device restore is refused unless this device has a worker it can see, so
  # the fixture pairs one the way the pairing screens do.
  defp detected_worker!(%DeviceWorkspace{} = workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, seen} = Pairing.mark_seen(worker)
    seen
  end

  defp restore_onto_device!(%DeviceWorkspace{} = workspace, project) do
    repository_id = "device-" <> Integer.to_string(System.unique_integer([:positive]))

    package = %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{"id" => project.id, "name" => project.name}
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => @repository_provider, "repository_id" => repository_id}
      },
      specifications: %PackageSection{name: :specifications, version: 1, content: []}
    }

    decision = %RestoreDecision{
      project_id: project.id,
      display_name: project.name,
      repository_provider: @repository_provider,
      repository_id: repository_id,
      checked_boundaries: [:device]
    }

    {:ok, %{project: restored}} =
      DeviceRestore.restore(workspace, package, decision,
        idempotency_key: "delivery-fixture-" <> project.id
      )

    restored
  end

  defp approve_through_domain!(authority, project, opts) do
    completed = complete_assessment!(authority, project, opts)

    {:ok, review} = RepositoryAssessments.profile_review(authority, completed.project_id)
    {:ok, profile} = RepositoryAssessments.approve_profile(authority, project.id, review.proposal)

    profile
  end

  defp complete_assessment!(authority, project, opts) do
    fields = Keyword.get(opts, :fields, @profile_fields)
    commit = Keyword.get(opts, :commit, @base_revision)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)

    {:ok, preparation} =
      RepositoryBindingPreparation.new(%{
        project_id: project.id,
        repository_provider: project.repository_provider,
        repository_id: repository_id(project),
        root: ".",
        commit: commit,
        scanner_contract_digest: @scanner_contract_digest,
        disclosure_digest: @assessment_disclosure_digest,
        worker_ref: Ecto.UUID.generate(),
        nonce: Ecto.UUID.generate(),
        issued_at: now,
        expires_at: DateTime.add(now, 120, :second)
      })

    {:ok, pending} = RepositoryAssessment.pending(preparation, now)
    {:ok, stored} = AssessmentStore.put(authority, pending)
    {:ok, command} = RepositoryAssessment.command(stored)
    {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command, fields))
    {:ok, payload} = RepositoryExecutionProfileProposalPayload.new(result, fields)

    {:ok, envelope} =
      WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

    {:ok, completed} =
      RepositoryAssessments.finish_assessment(
        authority,
        project.id,
        command,
        result,
        assessment_provenance!(command, result),
        now: now,
        proposal_envelope: envelope
      )

    completed
  end

  # A hosted project names its repository canonically; a device project keeps
  # the same identity under its own field.
  defp repository_id(%{canonical_repository_id: id}) when is_binary(id), do: id
  defp repository_id(%{repository_id: id}), do: id

  # The scan reports every directory the proposal's allowed scope names, so a
  # caller asking for its own scope gets evidence that supports it.
  defp completed_scan(command, fields) do
    directories = ["lib" | Map.get(fields, :allowed_scope, [])] |> Enum.uniq()

    %{
      protocol_version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository: %{provider: command.repository_provider, id: command.repository_id},
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      status: "completed",
      findings: @assessment_findings,
      structure: Enum.map(directories, &%{path: &1, kind: "directory"}),
      stats: %{discovered_paths: 16, inspected_files: 1, bytes_read: 20}
    }
  end

  defp assessment_provenance!(command, result) do
    {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
    {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

    {:ok, provenance} =
      RepositoryAssessmentCacheProvenance.new(%{
        source: "fresh_scan",
        cache_key_sha256: cache_key_sha256,
        evidence_sha256: evidence_sha256,
        cache_stored: true
      })

    provenance
  end

  @doc """
  Creates one feature in `Draft`, with the specification of its own that
  `Features.create/3` gives every feature.

  The fixture goes through the domain rather than inserting a row, so a feature
  in a test is in the state production actually produces. A hand-rolled row
  drifted from `Features.create/3` once already and made readiness look broken
  when only the fixture was.

  `requirements: :filled` writes a body under each guided heading, for a test
  that needs a feature no structural finding blocks. The default leaves the four
  headings empty, which is what a person sees on a feature they just created.
  """
  def feature_fixture(project, creator_account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    feature =
      created_feature!(project, creator_account, %{
        title: Map.get(attrs, :title, unique_title()),
        assigned_account_id: Map.get(attrs, :assigned_account_id)
      })

    write_requirements!(project, feature, Map.get(attrs, :requirements, :empty))
  end

  # Some fixtures deliberately attribute a feature to someone the guard refuses:
  # a member who has since left, or an identity whose participation the test is
  # about to change. Those create through the project's owner and correct the
  # attribution afterwards, so every feature still comes from the one production
  # path instead of a hand-rolled row that would drift from it again.
  defp created_feature!(project, creator_account, attrs) do
    case Features.create(project.id, actor_for(creator_account), attrs) do
      {:ok, feature} ->
        feature

      {:error, :unauthorized} ->
        {:ok, owner} = ParticipantGuard.owner(project.id)
        {:ok, feature} = Features.create(project.id, actor_for(owner), attrs)

        feature
        |> Ecto.Changeset.change(%{creator_account_id: creator_account.id})
        |> Repo.update!()
    end
  end

  defp actor_for(%{account_id: account_id}),
    do: %{account_id: account_id, hosted_identity_id: nil}

  defp actor_for(%{id: account_id}), do: %{account_id: account_id, hosted_identity_id: nil}

  @doc "The four guided bodies `requirements: :filled` writes."
  def filled_requirements, do: @filled_requirements

  defp write_requirements!(_project, feature, :empty), do: feature

  defp write_requirements!(project, feature, :filled) do
    authority = Repo.get(PersonalWorkspace, project.workspace_id)

    {:ok, current} =
      SpecificationStore.get_current(authority, project.id, feature.specification_id)

    {:ok, _appended} =
      SpecificationStore.append_revision(
        authority,
        project.id,
        feature.specification_id,
        current.revision.id,
        %{
          revision_id: Ecto.UUID.generate(),
          documents: %{
            requirements: GuidedRequirements.render(@filled_requirements),
            design: current.revision.design_document,
            tasks: current.revision.tasks_document
          }
        }
      )

    feature
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
  The manifest one continued attempt is bound to, rebuilt from the run, the
  attempt, and the approved execution profile.

  Neither store keeps the manifest itself, only its digest, so rebuilding it and
  comparing digests is the only way to prove which values a continuation really
  carried. The digest covers every field, so a match cannot happen by accident.
  """
  def continuation_manifest(run, attempt, profile, continuation) do
    {:ok, manifest} =
      ExecutionManifest.new(%{
        "manifest_version" => ExecutionManifest.manifest_version(),
        "project_id" => run.project_id,
        "feature_id" => run.feature_id,
        "run_id" => run.id,
        "attempt_number" => attempt.attempt_number,
        "approved_slice" => run.approved_slice,
        "starting_revision_id" => run.starting_revision_id,
        "starting_revision_digest" => run.starting_revision_digest,
        "effective_revision_id" => attempt.effective_revision_id,
        "effective_revision_digest" => attempt.effective_revision_digest,
        "repository_base_revision" => profile.base_revision,
        "target_branch" => run.branch,
        "required_checks" => required_check_contract(profile.required_checks),
        "repository_root" => profile.root,
        "commands" => profile.commands,
        "allowed_scope" => profile.allowed_scope,
        "agent_ref" => %{},
        "worker_ref" => %{},
        "continuation" => continuation
      })

    manifest
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
