# The whole module is compile-time gated, not just its route. A production
# build sets no `:e2e_bootstrap` flag, so this file compiles to nothing and the
# release contains no such module — there is no session-minting code to reach,
# reference, or re-enable. This goes further than the `/_ui` preview next to it
# in the router, which only gates its route, because this endpoint establishes
# authenticated sessions.
if Application.compile_env(:sdd_orchestrator, :e2e_bootstrap, false) do
  defmodule SddOrchestratorWeb.E2ERepositoryMetadataAdapter do
    @moduledoc """
    Deterministic metadata-only repository binding for the browser harness.

    It returns only the identity already present in the authorized request, the
    selected relative root, and one full commit. It implements no scan command
    and is excluded from production by the same compile-time gate as the
    session bootstrap that configures it.
    """
    @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

    @commit "0123456789abcdef0123456789abcdef01234567"

    def commit, do: @commit

    @impl true
    def prepare(request), do: response(request)

    @impl true
    def revalidate(request), do: response(request)

    defp response(request) do
      {:ok,
       %{
         repository_provider: request.repository_provider,
         repository_id: request.repository_id,
         root: request.selected_root,
         commit: @commit
       }}
    end
  end

  defmodule SddOrchestratorWeb.E2EPreviewAdapter do
    @moduledoc """
    A deterministic preview provider for the browser suite.

    It provisions nothing and reaches no network. The authorized path decides the
    answer: the ordinary path deploys and returns one participant-safe link, and
    a second authorized path always refuses, so one seeded feature can show both
    a preview a reader may open and one that failed with a stated reason.

    It exists only where the bootstrap controller does — behind the same
    compile-time flag — so no production build contains a preview provider that
    answers without a provider.
    """
    @behaviour SddOrchestrator.Delivery.PreviewAdapter

    @ready_path "web"
    @link "https://preview.e2e.test/branch-preview"

    @doc "The authorized path whose deployments succeed."
    def ready_path, do: @ready_path

    @doc "The authorized path whose deployments are always refused."
    def failing_path, do: "broken"

    @doc "The one participant-safe link a successful deployment serves."
    def link, do: @link

    @impl true
    def request(%{path: @ready_path}) do
      {:ok, %{status: "ready", provider_ref: "e2e-preview/deployment-1", link: @link}}
    end

    def request(_request) do
      {:ok, %{status: "failed", provider_ref: nil, link: nil, failure_reason: :quota_exhausted}}
    end

    @impl true
    def status(_query), do: {:ok, %{status: "pending", provider_ref: nil, link: nil}}

    @impl true
    def cleanup(_command), do: :ok
  end

  defmodule SddOrchestratorWeb.E2EBootstrapController do
    @moduledoc """
    Dev and test-only session and fixture bootstrap for the browser suite.

    A browser test cannot reach an authenticated product screen on its own: an
    application session is only issued by a live GitHub round trip, and a
    hosted session is only issued by a delivered passwordless credential.
    Neither is available to the local end-to-end server, which is why the
    authenticated participation and feature-delivery matrices were previously
    unprovable in a real browser.

    This endpoint establishes those two sessions directly and seeds the minimum
    project graph one scenario needs. The seeding itself runs the real domain
    commands — invitation creation, explicit acceptance, and the feature
    lifecycle transition table — so every seeded state is a state the product
    can actually produce, and the delivered invitation credential is read back
    out of the delivered message rather than reconstructed here.

    ## Why this cannot reach production

    Exclusion is by construction, in three layers. The module definition itself
    is wrapped in `Application.compile_env(:sdd_orchestrator, :e2e_bootstrap,
    false)`, and no production configuration sets that key, so a production
    build contains no such module at all. The router gates its route on the
    same flag, so there is also no route to dispatch. `create/2` then re-checks
    the flag at runtime and answers `404`, which keeps a build whose
    configuration is changed after compilation from serving anything.
    """
    use SddOrchestratorWeb, :controller

    alias SddOrchestrator.Accounts
    alias SddOrchestrator.Accounts.GitHubIdentity
    alias SddOrchestrator.AIRuntime.PersonalWorkerRPC
    alias SddOrchestrator.Devices
    alias SddOrchestrator.Devices.Pairing

    alias SddOrchestrator.Delivery.{
      AgentRun,
      ArtifactStore,
      EventIngestion,
      EvidenceIngestion,
      Features,
      Previews,
      ReviewHandoff,
      RunAttempt,
      VerificationCompletion,
      WorkerProtocol
    }

    alias SddOrchestrator.Devices
    alias SddOrchestrator.Devices.Pairing
    alias SddOrchestrator.HostedAccess
    alias SddOrchestrator.HostedAccess.Sessions
    alias SddOrchestrator.Participation
    alias SddOrchestrator.Participation.{Acceptance, Invitations}
    alias SddOrchestrator.Projects
    alias SddOrchestrator.Projects.Project
    alias SddOrchestrator.Repo

    alias SddOrchestrator.RepositoryAssessments

    alias SddOrchestrator.RepositoryAssessments.{
      AssessmentStore,
      BindingStore,
      RepositoryAssessment,
      RepositoryAssessmentCacheProvenance,
      RepositoryAssessmentResult,
      RepositoryBindingPreparation,
      RepositoryExecutionProfileProposalPayload,
      WorkerRepositoryExecutionProfileProposalEnvelope
    }

    alias SddOrchestratorWeb.{
      E2EPreviewAdapter,
      E2ERepositoryMetadataAdapter,
      HostedUserAuth,
      UserAuth
    }

    @columns ~w(draft ready_for_development in_development ready_for_review done)
    @owner_name "Robin Owner"
    @participant_name "Sam Member"
    @project_name "Delivery Pilot"
    @device_context %{user_agent_family: "E2E Browser", os_family: "E2E OS"}

    # The repository a configured scenario is registered against. Every scenario
    # builds its own owner, so its own workspace, and workspace-scoped repository
    # uniqueness is never contended by a fixed identity here.
    @repository %{
      "id" => 101,
      "owner" => "octo",
      "name" => "example",
      "full_name" => "octo/example",
      "private" => false,
      "visibility" => "public",
      "html_url" => "https://github.com/octo/example",
      "organization" => nil
    }

    # The one commit every seeded item of proof was recorded against. Sharing a
    # commit is what makes a rerun a replacement rather than a second opinion, so
    # the superseded item exists only because this value is the same for all of
    # them.
    @evidence_commit "4f9c2a7d1b8e6053c4af9d21e7b0356c8ad14e29"

    # The required-check contract the seeded attempt is bound to.
    @required_checks ["mix format --check-formatted", "mix credo --strict", "mix dialyzer"]

    # The repository revision a continued attempt's manifest is anchored to. It
    # is configuration, not evidence: the seeded runs prove their own commits.
    @repository_base_revision "a1b2c3d4e5f6a7b8"

    # The preview scenario verifies for real, so its attempt is bound to a
    # contract it can actually satisfy: one check, passed against one commit.
    @preview_checks ["mix test"]
    @preview_commit "9d3e1c07ab5642f8e0c1937bd4a5f26e0187cc34"
    @preview_provider "e2e-preview"

    # The exact commit the seeded execution-profile assessment is bound to, and
    # the reviewable proposal that assessment's evidence supports: project
    # commands and one required check were found, no repository instruction was,
    # and the evidence was ambiguous.
    @profile_commit "5c1d0e7a93b46f28ad0e5b71c4f39268ba07de51"
    @profile_check "mix test"
    @profile_gap "missing_repository_instructions"
    @profile_conflict "ambiguous_command_evidence"

    @profile_proposal %{
      commands: ["make check", @profile_check],
      required_checks: [@profile_check],
      allowed_scope: [".", "lib"],
      gaps: [@profile_gap],
      conflicts: [@profile_conflict],
      multi_root_blockers: []
    }

    # One real 1x1 PNG, so the stored screenshot genuinely is the content type it
    # declares and survives the store's own digest and content-type checks rather
    # than being waved through.
    @screenshot_png Base.decode64!(
                      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
                    )

    @doc """
    Seeds one scenario, establishes its sessions, and returns its identifiers.

    Answers `404` unless the harness flag is set, so the action is inert even if
    it is somehow compiled into a build that should not serve it.
    """
    def create(conn, params) do
      if enabled?() do
        run(conn, params["scenario"], params)
      else
        send_resp(conn, :not_found, "")
      end
    end

    defp enabled?, do: Application.get_env(:sdd_orchestrator, :e2e_bootstrap, false) == true

    # One hosted project whose owner is signed in through the application
    # session. `owner_profile=false` leaves the owner label unset so the browser
    # can drive the "choose your name before inviting anyone" prerequisite.
    defp run(conn, "project_owner", params) do
      owner = new_owner()
      project = new_project(owner)
      profile? = params["owner_profile"] != "false"

      if profile?, do: save_owner_profile(project, owner)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: (profile? && @owner_name) || nil
      })
    end

    # One hosted project with an established owner, one participant who joined
    # through the real acceptance flow, and one still-pending invitation.
    defp run(conn, "project_member", params) do
      %{project: project, owner: owner, participant: participant, pending: pending} =
        member_graph()

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        owner_email: email_of(owner),
        participant_name: @participant_name,
        participant_email: email_of(participant),
        pending_email: pending
      })
    end

    # One pending invitation, reachable through the credential that was actually
    # delivered. `as` decides which identity holds the browser: nobody, the
    # invited address, or an unrelated signed-in identity.
    defp run(conn, "invitation", params) do
      owner = new_owner()
      project = new_project(owner)
      save_owner_profile(project, owner)

      invited_email = unique_email("invited")

      {:ok, %{invitation: invitation}} =
        Invitations.create(project, owner.account.id, invited_email)

      conn
      |> sign_in_invitee(params["as"] || "none", invited_email)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        invited_email: invited_email,
        invitation_id: invitation.id,
        invitation_path: delivered_invitation_path(invitation.id),
        acceptance_path: "/projects/invitations/#{invitation.id}/accept"
      })
    end

    # One hosted project whose board is either empty or holds one feature in each
    # of the five columns, with a visible status on the in-development card. The
    # project always has a second member so the assignment selector has a real
    # choice to make. `configured=true` registers the project through the real
    # onboarding transaction instead of inserting a bare row, which is what gives
    # it the repository connection and hosted storage the landing decision reads.
    defp run(conn, "features", params) do
      %{project: project, owner: owner, participant: participant} =
        member_graph(configured?: params["configured"] == "true")

      actor = %{account_id: owner.account.id, hosted_identity_id: nil}

      features =
        if params["populated"] == "true",
          do: seed_features(owner.personal_workspace, project, actor),
          else: %{}

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        participant_name: @participant_name,
        features: features
      })
    end

    # One hosted project holding a feature that has actually been worked on: a
    # run, its current attempt, and the spread of recorded proof a reviewer has
    # to be able to tell apart — a passed, a failed, and a missing required
    # check, a screenshot with real stored bytes beside one the environment could
    # not take, and an earlier result a rerun replaced.
    defp run(conn, "evidence", params) do
      %{project: project, owner: owner, participant: participant} = member_graph()
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}

      {:ok, feature} = Features.create(project.id, actor, %{title: "Reviewed feature"})
      feature = advance(project.id, actor, feature, "ready_for_review")

      %{run: run, evidence: evidence} =
        seed_evidence(owner.personal_workspace, project, feature)

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        participant_name: @participant_name,
        feature_id: feature.id,
        branch: run.branch,
        commit_sha: @evidence_commit,
        evidence: evidence
      })
    end

    # One hosted project whose feature verified twice and has both preview
    # outcomes a reader must be able to tell apart: a deployment that succeeded
    # and offers one safe link, and one the provider refused, which offers none.
    # The feature then reaches `Ready for review` regardless, which is the point.
    defp run(conn, "preview", params) do
      %{project: project, owner: owner, participant: participant} = member_graph()
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}
      authority = owner.personal_workspace

      {:ok, feature} = Features.create(project.id, actor, %{title: "Previewed feature"})
      feature = start_development(project.id, actor, feature)

      authorize_preview(project)

      ready = seed_preview(authority, project, feature, E2EPreviewAdapter.ready_path())
      failed = seed_preview(authority, project, feature, E2EPreviewAdapter.failing_path())

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(authority, project.id, failed.run)

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        feature_id: feature.id,
        commit_sha: @preview_commit,
        preview_link: E2EPreviewAdapter.link(),
        preview_provider: @preview_provider,
        ready_branch: ready.run.branch,
        failed_branch: failed.run.branch
      })
    end

    # One hosted project holding a feature that genuinely reached `Ready for
    # review`: a run that verified for real, the preview that verification
    # authorized, and the recorded handoff a decision is checked against. The
    # `evidence` scenario cannot stand in for this — it reaches the column by
    # walking the transition table, so it has no verified completion behind it
    # and a review of it would be refused.
    #
    # Nobody is assigned, so responsibility resolves to the creator, who is the
    # owner. `as` therefore decides whether the browser holds someone who may
    # decide or a participant who may not, which is what makes the refusal
    # provable in a real browser rather than only in a unit test.
    defp run(conn, "review", params) do
      %{project: project, owner: owner, participant: participant} = member_graph()
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}
      authority = owner.personal_workspace

      {:ok, feature} = Features.create(project.id, actor, %{title: "Feature awaiting review"})
      feature = start_development(project.id, actor, feature)

      authorize_preview(project)
      configure_continuation()

      ready = seed_preview(authority, project, feature, E2EPreviewAdapter.ready_path())

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(authority, project.id, ready.run)

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        participant_name: @participant_name,
        feature_id: feature.id,
        branch: ready.run.branch,
        commit_sha: @preview_commit,
        preview_link: E2EPreviewAdapter.link()
      })
    end

    # One configured hosted project plus one reachable paired worker for the
    # disclosure-confirmed repository-assessment start flow. The adapter is the
    # compile-time-gated metadata-only double above; no scanner or command
    # transport is configured by this scenario.
    defp run(conn, "repository_assessment", _params) do
      owner = new_owner()
      project = registered_project(owner)
      save_owner_profile(project, owner)
      {:ok, device_workspace} = Devices.establish_workspace()
      worker = reachable_worker(device_workspace.id)
      :ok = BindingStore.reset()

      Application.put_env(
        :sdd_orchestrator,
        :repository_metadata_adapter,
        E2ERepositoryMetadataAdapter
      )

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        worker_id: worker.id,
        commit: E2ERepositoryMetadataAdapter.commit()
      })
    end

    # One configured hosted project whose newest assessment completed and stored
    # its worker proposal envelope, so the owner-review screen has a real
    # reviewable proposal. Every value is produced by the assessment domain
    # itself — binding, command, completed result, cache provenance, and the
    # worker envelope — rather than inserted.
    defp run(conn, "repository_execution_profile", _params) do
      owner = new_owner()
      project = registered_project(owner)
      save_owner_profile(project, owner)
      completed = seed_completed_assessment(owner, project)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        commit: completed.commit,
        command: @profile_check,
        gap: @profile_gap,
        conflict: @profile_conflict
      })
    end

    # One signed-in account and the current device authority with a deterministic
    # personal-worker state. The ready and mixed variants attach responders to
    # the real PersonalWorkerRPC registry; each link returns a fresh opaque
    # worker-local profile reference and only the exact safe adapter fields.
    defp run(conn, "ai_connections", params) do
      owner = new_owner()
      seed_github_identity(owner.account)
      project = new_project(owner)
      {:ok, workspace} = Devices.establish_workspace()

      workspace.id
      |> Pairing.active_workers()
      |> Enum.each(fn worker -> {:ok, _revoked} = Pairing.revoke_worker(worker) end)

      worker_state = params["worker_state"] || "ready"
      seed_ai_workers(workspace.id, worker_state)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        worker_state: worker_state
      })
    end

    defp run(conn, _unknown_scenario, _params),
      do: conn |> put_status(:bad_request) |> json(%{error: "unknown scenario"})

    ## Scenario building blocks

    defp member_graph(opts \\ []) do
      owner = new_owner()

      project =
        if Keyword.get(opts, :configured?, false),
          do: registered_project(owner),
          else: new_project(owner)

      save_owner_profile(project, owner)

      participant = join_project(project, owner, unique_email("member"))
      pending = unique_email("pending")
      {:ok, _invitation} = Invitations.create(project, owner.account.id, pending)

      %{project: project, owner: owner, participant: participant, pending: pending}
    end

    defp seed_completed_assessment(owner, project) do
      authority = {:hosted, owner.account.id}
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, preparation} =
        RepositoryBindingPreparation.new(%{
          project_id: project.id,
          repository_provider: project.repository_provider,
          repository_id: project.canonical_repository_id,
          root: ".",
          commit: @profile_commit,
          scanner_contract_digest: content_digest("e2e-profile-scanner"),
          disclosure_digest: content_digest("e2e-profile-disclosure"),
          worker_ref: Ecto.UUID.generate(),
          nonce: Ecto.UUID.generate(),
          issued_at: now,
          expires_at: DateTime.add(now, 120, :second)
        })

      {:ok, pending} = RepositoryAssessment.pending(preparation, now)
      {:ok, stored} = AssessmentStore.put(authority, pending)
      {:ok, command} = RepositoryAssessment.command(stored)
      {:ok, result} = RepositoryAssessmentResult.completed(command, profile_scan(command))
      {:ok, payload} = RepositoryExecutionProfileProposalPayload.new(result, @profile_proposal)

      {:ok, envelope} =
        WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

      {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
      {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

      {:ok, provenance} =
        RepositoryAssessmentCacheProvenance.new(%{
          source: "fresh_scan",
          cache_key_sha256: cache_key_sha256,
          evidence_sha256: evidence_sha256,
          cache_stored: true
        })

      {:ok, completed} =
        RepositoryAssessments.finish_assessment(
          authority,
          project.id,
          command,
          result,
          provenance,
          now: now,
          proposal_envelope: envelope
        )

      completed
    end

    defp profile_scan(command) do
      %{
        protocol_version: command.version,
        assessment_id: command.assessment_id,
        project_id: command.project_id,
        repository: %{provider: command.repository_provider, id: command.repository_id},
        root: command.root,
        commit: command.commit,
        scanner_contract_digest: command.scanner_contract_digest,
        status: "completed",
        findings: [
          %{
            category: "check",
            path: "Makefile",
            bytes: 24,
            sha256: content_digest("e2e-profile-makefile"),
            line_count: 3
          }
        ],
        structure: [%{path: "lib", kind: "directory"}],
        stats: %{discovered_paths: 4, inspected_files: 1, bytes_read: 24}
      }
    end

    defp reachable_worker(device_workspace_id) do
      {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

      {:ok, %{worker: worker}} =
        Pairing.complete_pairing(code, %{
          os_family: "macos",
          os_major: "15",
          app_version: "1.0.0",
          protocol_version: "1"
        })

      {:ok, worker} = Pairing.mark_seen(worker)
      worker
    end

    defp seed_ai_workers(_workspace_id, "missing"), do: :ok

    defp seed_ai_workers(workspace_id, "unavailable") do
      _worker = pair_ai_worker(workspace_id)
      :ok
    end

    defp seed_ai_workers(workspace_id, "incompatible") do
      worker = pair_ai_worker(workspace_id)

      start_ai_responder(workspace_id, worker,
        protocol_version: "personal-ai/0",
        capabilities: ["connection/1"]
      )
    end

    defp seed_ai_workers(workspace_id, "mixed") do
      _unavailable = pair_ai_worker(workspace_id)
      incompatible = pair_ai_worker(workspace_id)
      ready = pair_ai_worker(workspace_id)

      start_ai_responder(workspace_id, incompatible,
        protocol_version: "personal-ai/0",
        capabilities: ["connection/1"]
      )

      start_ai_responder(workspace_id, ready)
    end

    defp seed_ai_workers(workspace_id, _ready) do
      worker = pair_ai_worker(workspace_id)
      start_ai_responder(workspace_id, worker)
    end

    defp pair_ai_worker(workspace_id) do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

      {:ok, %{worker: worker}} =
        Pairing.complete_pairing(code, %{
          os_family: "macos",
          app_version: "1.0.0",
          protocol_version: "personal-ai/1"
        })

      worker
    end

    defp seed_github_identity(account) do
      suffix = System.unique_integer([:positive])

      %GitHubIdentity{}
      |> GitHubIdentity.changeset(%{
        github_user_id: suffix,
        login: "e2e-user-#{suffix}",
        avatar_url: nil,
        account_id: account.id
      })
      |> Repo.insert!()
    end

    defp start_ai_responder(workspace_id, worker, opts \\ []) do
      parent = self()
      ready_ref = make_ref()

      spawn(fn ->
        contract = %{
          protocol_version: Keyword.get(opts, :protocol_version, "personal-ai/1"),
          capabilities: Keyword.get(opts, :capabilities, ["connection/1"])
        }

        result = PersonalWorkerRPC.attach(workspace_id, worker.id, contract)
        send(parent, {ready_ref, result})
        ai_responder_loop()
      end)

      receive do
        {^ready_ref, {:ok, _registry}} -> :ok
      after
        1_000 -> raise "personal AI responder did not attach"
      end
    end

    defp ai_responder_loop do
      receive do
        {:ai_request, envelope, caller, request_ref, _deadline} ->
          Process.sleep(150)

          result = %{
            "worker_profile_ref" => "e2e-profile-#{unique_suffix()}",
            "provider" => "openai_codex",
            "authentication_mode" => envelope["params"]["authentication_mode"],
            "availability" => "available",
            "adapter_compatibility_version" => "connection/1"
          }

          send(caller, {PersonalWorkerRPC, request_ref, {:ok, result}})
          ai_responder_loop()

        {:cancel_ai_request, _request_id} ->
          ai_responder_loop()
      end
    end

    # The participant joins the way a real one does: the owner invites the
    # address, that address becomes a verified hosted identity, and acceptance is
    # explicit.
    defp join_project(project, owner, email) do
      {:ok, %{invitation: invitation}} = Invitations.create(project, owner.account.id, email)
      invitee = hosted_identity!(email)

      {:ok, _accepted} =
        Acceptance.accept(invitation.id, invitee.hosted_identity, @participant_name)

      invitee
    end

    defp new_owner, do: hosted_identity!(unique_email("owner"))

    # A project with no repository connection and no storage: the state a browser
    # test needs to prove that setup is not skipped.
    defp new_project(owner) do
      %Project{}
      |> Project.changeset(%{name: @project_name, workspace_id: owner.personal_workspace.id})
      |> Repo.insert!()
    end

    # The same project the product would have produced: the onboarding attempt is
    # confirmed through the real registration transaction, so the repository
    # connection and hosted storage exist because they were created the way they
    # normally are rather than asserted into place here.
    defp registered_project(owner) do
      workspace = owner.personal_workspace

      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
      {:ok, attempt} = Projects.select_repository(workspace, attempt.id, @repository)
      {:ok, attempt} = Projects.select_storage_mode(workspace, attempt.id, "hosted")
      {:ok, project} = Projects.register_project(workspace, attempt, name: @project_name)

      project
    end

    defp save_owner_profile(project, owner) do
      {:ok, _profile} = Participation.save_owner_profile(project, owner.account.id, @owner_name)
      :ok
    end

    defp hosted_identity!(email) do
      {:ok, identity} = HostedAccess.restore_or_create_identity(email)
      identity
    end

    defp seed_features(authority, project, actor) do
      Map.new(@columns, fn column ->
        {:ok, feature} =
          Features.create(project.id, actor, %{title: "#{column_title(column)} feature"})

        feature = advance(project.id, actor, feature, column)

        if column == "in_development", do: seed_progress(authority, project, feature)

        {column, feature.id}
      end)
    end

    defp seed_progress(authority, project, feature) do
      %{run: run, attempt: attempt} = seed_run(project, feature, [])

      {:ok, _results} =
        EventIngestion.ingest(authority, project.id, progress_event(run, attempt, 1))

      :ok
    end

    # Every column is reached by walking the legal transition table from `Draft`,
    # so the seeded board could have been produced by the product itself.
    defp advance(project_id, actor, feature, target) do
      target_index = Enum.find_index(@columns, &(&1 == target))

      @columns
      |> Enum.slice(1..target_index//1)
      |> Enum.reduce(feature, fn column, current ->
        {:ok, moved} = Features.transition(project_id, actor, current, column, status(column))
        moved
      end)
    end

    defp status("in_development"), do: [status: "blocked"]
    defp status(_column), do: []

    defp column_title(column),
      do: column |> String.replace("_", " ") |> String.capitalize()

    ## Verification evidence

    # Every item goes through the real ingestion path rather than an insert, so a
    # seeded result is one a worker could actually have produced: the envelope is
    # proved against the protocol, the fence, and the attempt's sequence, and the
    # branch is taken from the run rather than from the event.
    defp seed_evidence(authority, project, feature) do
      %{run: run, attempt: attempt} = seed_run(project, feature)

      evidence =
        authority
        |> store_screenshot(project.id)
        |> evidence_payloads()
        |> Enum.with_index(1)
        |> Enum.map(&record_evidence(authority, project, run, attempt, &1))

      %{run: run, evidence: evidence}
    end

    ## Branch previews

    # Preview authorization is preconfigured and per project, so the seeded
    # project is added to the configured list rather than replacing it: an
    # earlier scenario's project must not lose its preview path because a later
    # one asked for its own.
    defp authorize_preview(project) do
      config = Application.get_env(:sdd_orchestrator, :preview, [])

      projects =
        config
        |> Keyword.get(:projects, %{})
        |> Map.put(project.id, [
          E2EPreviewAdapter.ready_path(),
          E2EPreviewAdapter.failing_path()
        ])

      Application.put_env(:sdd_orchestrator, :preview,
        adapter: E2EPreviewAdapter,
        provider: @preview_provider,
        credential_ref: nil,
        request_timeout_ms: 300_000,
        ttl_seconds: 86_400,
        projects: projects
      )
    end

    ## Rejected-work continuation

    # Sending work back continues the run that produced it, so a rejection plans
    # the next attempt's execution manifest in the same commit as its verdict,
    # and a declared contradiction locates that run's own workspace before it
    # opens a question about it. Neither is configured in the environment this
    # harness serves, and `Review.reject/5` would raise rather than refuse
    # without them — which would prove the review screen against a crash instead
    # of against the domain.
    #
    # The values are the ordinary configured boundary rather than anything the
    # browser supplies: nothing a reviewer types may reach a manifest.
    defp configure_continuation do
      Application.put_env(:sdd_orchestrator, :delivery_execution,
        approved_slice: "slice-07",
        repository_base_revision: @repository_base_revision,
        required_checks: [],
        agent_ref: %{"provider" => "e2e-agent"},
        worker_ref: %{"target" => "e2e-worker"}
      )

      Application.put_env(:sdd_orchestrator, :worker_workspace_root, workspace_root())
    end

    # Containment is decided against the root's real location, so the root has to
    # be a directory that exists rather than a plausible string. The path is a
    # literal under this machine's temporary directory and carries nothing from a
    # request. Documented false positive.
    # sobelow_skip ["Traversal.FileModule"]
    defp workspace_root do
      root = Path.join(System.tmp_dir!(), "sdd-orchestrator-e2e-workspaces")
      File.mkdir_p!(root)
      root
    end

    # One run that genuinely verified, then the preview that verification
    # authorizes. `Previews.start/4` reads the recorded completion itself, so a
    # seeded preview is one the product would have produced rather than a row.
    defp seed_preview(authority, project, feature, path) do
      %{run: run, attempt: attempt} = seed_run(project, feature, @preview_checks)

      {:ok, _passed} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, 1, verified_check_payload(hd(@preview_checks)))
        )

      {:ok, _verified} =
        VerificationCompletion.ingest(
          authority,
          project.id,
          completion_event(run, attempt, 2)
        )

      {:ok, %{deployment: deployment}} =
        Previews.start(authority, project.id, run, path: path)

      %{run: run, attempt: attempt, deployment: deployment}
    end

    defp verified_check_payload(name) do
      %{
        "source" => "check",
        "kind" => "required_check",
        "name" => name,
        "outcome" => "passed",
        "command" => name,
        "exit_code" => 0,
        "duration_ms" => 1_200,
        "commit_sha" => @preview_commit,
        "digest" => content_digest("#{name}-#{@preview_commit}"),
        "redacted" => false
      }
    end

    defp completion_event(run, attempt, sequence) do
      unique = unique_suffix()

      %{
        "type" => "event",
        "protocol_version" => WorkerProtocol.version(),
        "event_id" => "evt-#{unique}",
        "run_id" => run.id,
        "command_id" => "cmd-#{unique}",
        "attempt_number" => attempt.attempt_number,
        "fence_token" => attempt.fence_token,
        "sequence" => sequence,
        "event_type" => "verification_completed",
        "source" => "worker",
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{
          "branch" => run.branch,
          "revision_id" => attempt.effective_revision_id,
          "commit_sha" => @preview_commit
        }
      }
    end

    defp progress_event(run, attempt, sequence) do
      unique = unique_suffix()

      %{
        "type" => "event",
        "protocol_version" => WorkerProtocol.version(),
        "event_id" => "evt-#{unique}",
        "run_id" => run.id,
        "command_id" => "cmd-#{unique}",
        "attempt_number" => attempt.attempt_number,
        "fence_token" => attempt.fence_token,
        "sequence" => sequence,
        "event_type" => "progress",
        "source" => "agent",
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{"summary" => "Ran the focused implementation checks"}
      }
    end

    # The preview scenario needs a feature that is genuinely in development and
    # not also blocked, because a blocked status would survive into review and
    # say something about the run that is not true.
    defp start_development(project_id, actor, feature) do
      Enum.reduce(["ready_for_development", "in_development"], feature, fn column, current ->
        {:ok, moved} = Features.transition(project_id, actor, current, column, [])
        moved
      end)
    end

    defp seed_run(project, feature, checks \\ @required_checks) do
      suffix = unique_suffix()

      run =
        %AgentRun{}
        |> AgentRun.create_changeset(%{
          project_id: project.id,
          feature_id: feature.id,
          starting_revision_id: "rev-#{suffix}",
          starting_revision_digest: content_digest("rev-#{suffix}"),
          approved_slice: "slice-07",
          branch: "sdd/evidence-#{suffix}"
        })
        |> Repo.insert!()

      attempt =
        %RunAttempt{}
        |> RunAttempt.create_changeset(%{
          run_id: run.id,
          attempt_number: 1,
          continuation_reason: "initial",
          effective_revision_id: run.effective_revision_id,
          effective_revision_digest: run.effective_revision_digest,
          manifest_digest: content_digest("manifest-#{run.id}"),
          required_checks: Enum.map(checks, &%{"name" => &1, "command" => &1}),
          fence_token: 1
        })
        |> Repo.insert!()

      %{run: run, attempt: attempt}
    end

    # The bytes have to survive an authenticated store before any event may name
    # them, which is exactly what makes the captured screenshot below believable
    # instead of merely described.
    defp store_screenshot(authority, project_id) do
      {:ok, ref} =
        ArtifactStore.put(authority, project_id, %{
          content: @screenshot_png,
          content_type: "image/png",
          digest: content_digest(@screenshot_png),
          redacted: false
        })

      ref
    end

    defp evidence_payloads(artifact_ref) do
      [
        check_payload("mix format --check-formatted", "failed", 1),
        check_payload("mix credo --strict", "failed", 1),
        check_payload("mix dialyzer", "missing", 127),
        captured_screenshot_payload(artifact_ref),
        unsupported_screenshot_payload(),
        # The rerun. Same check against the same commit, so it replaces the first
        # result rather than sitting beside it as a second opinion.
        check_payload("mix format --check-formatted", "passed", 0)
      ]
    end

    # A required check has to say what it ran and how that ended even when the
    # result is an absence, so `missing` carries its command and exit code too.
    defp check_payload(name, outcome, exit_code) do
      %{
        "source" => "check",
        "kind" => "required_check",
        "name" => name,
        "outcome" => outcome,
        "command" => name,
        "exit_code" => exit_code,
        "duration_ms" => 2_400,
        "commit_sha" => @evidence_commit,
        "digest" => content_digest("#{name}-#{outcome}"),
        "redacted" => false
      }
    end

    defp captured_screenshot_payload(artifact_ref) do
      %{
        "source" => "worker",
        "kind" => "screenshot",
        "name" => "Feature board after the change",
        "capture_result" => "captured",
        "command" => "capture --screen feature-board",
        "duration_ms" => 5_100,
        "commit_sha" => @evidence_commit,
        "digest" => content_digest(@screenshot_png),
        "redacted" => false,
        "artifact_ref" => artifact_ref
      }
    end

    # An absence claim may not smuggle content, so this one names no artifact at
    # all. Its outcome comes from the reported capture result, never from here.
    defp unsupported_screenshot_payload do
      %{
        "source" => "worker",
        "kind" => "screenshot",
        "name" => "Feature board on a small screen",
        "capture_result" => "unsupported",
        "command" => "capture --screen feature-board --device mobile",
        "duration_ms" => 300,
        "commit_sha" => @evidence_commit,
        "digest" => content_digest("screenshot-unsupported"),
        "redacted" => false
      }
    end

    defp record_evidence(authority, project, run, attempt, {payload, sequence}) do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence, payload)
        )

      %{
        id: evidence.id,
        kind: evidence.kind,
        name: evidence.name,
        outcome: evidence.outcome,
        digest: evidence.digest
      }
    end

    defp evidence_event(run, attempt, sequence, payload) do
      unique = unique_suffix()

      %{
        "type" => "event",
        "protocol_version" => WorkerProtocol.version(),
        "event_id" => "evt-#{unique}",
        "run_id" => run.id,
        "command_id" => "cmd-#{unique}",
        "attempt_number" => attempt.attempt_number,
        "fence_token" => attempt.fence_token,
        "sequence" => sequence,
        "event_type" => "evidence",
        "source" => Map.fetch!(payload, "source"),
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => Map.delete(payload, "source")
      }
    end

    defp content_digest(content),
      do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    ## Sessions

    defp sign_in(conn, "participant", _owner, participant),
      do: sign_in_hosted(conn, participant.hosted_identity)

    defp sign_in(conn, _as, owner, _participant), do: sign_in_account(conn, owner.account)

    defp sign_in_invitee(conn, "invited", email),
      do: sign_in_hosted(conn, hosted_identity!(email).hosted_identity)

    defp sign_in_invitee(conn, "other", _email),
      do: sign_in_hosted(conn, new_owner().hosted_identity)

    defp sign_in_invitee(conn, _as, _email), do: conn

    defp sign_in_account(conn, account) do
      {:ok, token} = Accounts.create_session(account)
      UserAuth.put_session_token(conn, token)
    end

    defp sign_in_hosted(conn, hosted_identity) do
      {:ok, _session, session_cookie} = Sessions.create(hosted_identity, @device_context)
      HostedUserAuth.put_session_cookie(conn, session_cookie)
    end

    ## Delivered credential

    # The invitation credential is never stored in a readable form, so the
    # harness recovers the acceptance link the same way the invited person does:
    # out of the message that was delivered to them.
    defp delivered_invitation_path(invitation_id) do
      pattern = Regex.compile!("/projects/invitations/#{invitation_id}/accept\\?\\S+")

      Swoosh.Adapters.Local.Storage.Memory.all()
      |> Enum.find_value(fn email ->
        case Regex.run(pattern, email.text_body || "") do
          [path] -> path
          nil -> nil
        end
      end)
    end

    ## Unique values

    defp email_of(identity) do
      identity.hosted_identity
      |> Repo.preload(:external_identities)
      |> Map.fetch!(:external_identities)
      |> Enum.find_value(&(&1.provider == "email" && &1.display_identifier))
    end

    defp unique_email(prefix), do: "#{prefix}-#{unique_suffix()}@example.com"

    defp unique_suffix do
      8 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    end
  end
end
