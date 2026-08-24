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

  defmodule SddOrchestratorWeb.E2EPersonalConnectionAdapter do
    @moduledoc """
    A deterministic personal-AI-connection adapter for the browser suite
    (specs/12 Task 8's own e2e proof).

    No worker pairing, no `SddOrchestrator.AIRuntime.PersonalWorkerRPC` round
    trip: `link_personal_connection/4` accepts an explicit `adapter:`
    override, so this returns the exact safe result the caller already
    decided on through `opts[:adapter_result]` — mirroring
    `SddOrchestrator.PersonalConnectionAdapterDouble` (test-only, unavailable
    to a `mix phx.server` build) closely enough to prove the same contract
    without depending on it. Exists only behind the same compile-time flag
    as the rest of this file.
    """
    @behaviour SddOrchestrator.AIRuntime.PersonalConnectionAdapter

    @impl true
    def link(_account, worker, request, opts) do
      Keyword.get_lazy(opts, :adapter_result, fn ->
        {:ok,
         %{
           worker_profile_ref: "e2e-profile-#{worker.id}",
           provider: request.provider,
           authentication_mode: request.authentication_mode,
           availability: "available",
           adapter_compatibility_version: "connection/1"
         }}
      end)
    end

    @impl true
    def revoke(_account, _worker, request, _opts) do
      {:ok, %{worker_profile_ref: request.worker_profile_ref, credential_removal: "removed"}}
    end
  end

  defmodule SddOrchestratorWeb.E2EModelCatalogAdapter do
    @moduledoc """
    A deterministic model-catalog adapter for the browser suite, mirroring
    `SddOrchestratorWeb.E2EPersonalConnectionAdapter`'s reasoning: `fetch/3`
    returns the caller's own `opts[:adapter_result]` rather than a live
    `model/list` round trip.
    """
    @behaviour SddOrchestrator.AIRuntime.ModelCatalogAdapter

    @impl true
    def fetch(_account, _connection, opts), do: Keyword.fetch!(opts, :adapter_result)
  end

  defmodule SddOrchestratorWeb.E2EQuotaAdapter do
    @moduledoc """
    A deterministic quota adapter for the browser suite, mirroring
    `SddOrchestratorWeb.E2EModelCatalogAdapter`. The project assistant never
    reads exact quota (AC-22); this exists only so
    `SddOrchestrator.AIRuntime.RuntimeSessions.pin_session/3` has a current
    quota snapshot to evaluate policy against on the way to `:available`.
    """
    @behaviour SddOrchestrator.AIRuntime.QuotaAdapter

    @impl true
    def fetch(_account, _connection, opts), do: Keyword.fetch!(opts, :adapter_result)
  end

  defmodule SddOrchestratorWeb.E2EModelCompletionAdapter do
    @moduledoc """
    A deterministic `SddOrchestrator.ProjectAssistant.ModelCompletionAdapter`
    for the browser suite (specs/12 Task 8's own e2e proof) — no live model
    call. Scenarios are keyed off `question_text`'s prefix, the same
    convention `SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter`
    (test-only, unavailable to a `mix phx.server` build) already proved in
    Task 7's own focused tests; this carries only the small subset the
    browser suite actually exercises end to end:

      * `"spec-valid: "` — cites the current context's first specification
        with its exact current revision, so a real, readable citation opens.
      * `"repository-valid: "` — cites a repository path. No worker is ever
        bound to the seeded e2e project, so this always resolves as a
        visible `:unavailable` uncertainty marker rather than a citation —
        proving the source-unavailable degraded state inside a real turn.
      * `"fails: model_unavailable"` — the one normalized model-completion
        failure the browser suite exercises, so a real `outcome: "failed"`
        turn and its retry affordance render.
      * any other question — one plain, non-material remark.

    `"fails: model_unavailable"` returns the literal `:model_unavailable`
    atom rather than converting the question text's own suffix to an atom
    (via `String.to_atom/1` or `String.to_existing_atom/1`): this compile-time
    build (`mix phx.server`, never a release) loads each module into the
    running node lazily, on first call, rather than all at once, so whether
    an incidentally-named atom is already registered in this process's atom
    table depends on unrelated module-loading history, not on anything this
    module's own contract guarantees — `String.to_existing_atom/1` raised
    `ArgumentError: not an already existing atom` here exactly when no other
    already-invoked code path happened to have loaded a module that mentions
    `:model_unavailable` as a literal first. A closed match on the one
    question text this suite actually sends removes that dependency
    entirely, and keeps the module's own "small, closed subset" contract
    (see above) rather than reopening the `String.to_atom/1` unbounded-atom
    Sobelow finding this file's history already resolved once.
    """
    @behaviour SddOrchestrator.ProjectAssistant.ModelCompletionAdapter

    @impl true
    def complete(%{question_text: "fails: model_unavailable"}), do: {:error, :model_unavailable}

    def complete(%{question_text: "spec-valid: " <> _rest, context_content: content}) do
      [entry | _rest] = content["specifications"]

      claims = [
        %{
          text: "The current specification is #{entry["title"]}.",
          material: true,
          citation: %{
            type: :specification,
            specification_id: entry["id"],
            revision_id: entry["revision_id"]
          }
        }
      ]

      {:ok, %{claims: claims, markers: []}}
    end

    def complete(%{question_text: "repository-valid: " <> _rest}) do
      claims = [
        %{
          text: "The repository shows this at lib/app.ex:1-2.",
          material: true,
          citation: %{type: :repository, path: "lib/app.ex", start_line: 1, end_line: 2}
        }
      ]

      {:ok, %{claims: claims, markers: []}}
    end

    def complete(%{question_text: _other}) do
      {:ok,
       %{
         claims: [
           %{text: "This is a general, non-material remark.", material: false, citation: nil}
         ],
         markers: []
       }}
    end
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

    alias SddOrchestrator.AIRuntime.{
      ModelCatalogs,
      PersonalConnections,
      PersonalWorkerRPC,
      Quotas
    }

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
    alias SddOrchestrator.Devices.PortableRepositoryIdentity
    alias SddOrchestrator.HostedAccess
    alias SddOrchestrator.HostedAccess.Sessions
    alias SddOrchestrator.Notifications
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

    alias SddOrchestrator.RepositoryKits
    alias SddOrchestrator.SpecificationStore

    alias SddOrchestratorWeb.{
      E2EModelCatalogAdapter,
      E2EPersonalConnectionAdapter,
      E2EPreviewAdapter,
      E2EQuotaAdapter,
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

    # The one current authoritative specification the pilot scenario adopts.
    @pilot_specification_title "Bounded pilot feature"

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

    # One hosted project whose repository is a local Git repository, plus one
    # active paired worker on this machine. The project's identity is generated
    # from the folder the worker stand-in's picker actually opens, so the
    # connection is proved against a real repository rather than a fixture that
    # only looks like one.
    #
    # The device workspace is this machine's own and is shared with every other
    # scenario that pairs a worker, so this seeds one reachable machine rather
    # than asserting it is the only one.
    defp run(conn, "hosted_local_repository_project", _params) do
      owner = new_owner()
      {:ok, repository_id} = PortableRepositoryIdentity.generate(stub_repository())
      project = new_local_repository_project(owner, repository_id)
      pair_available_worker()

      conn
      |> sign_in_account(owner.account)
      |> json(%{project_id: project.id, project_name: project.name})
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

    # One hosted project whose owner holds two guided-delivery notifications
    # addressed to their own application account, exactly the way the real
    # projector delivers them: one still unread and pointing at a real feature,
    # and one already marked read. Notification reads require a hard
    # application-session gate (specs/17 Task 4), so this scenario signs in
    # through `sign_in_account` only — there is no hosted-identity variant.
    defp run(conn, "notifications", _params) do
      %{project: project, owner: owner} = member_graph()
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}

      {:ok, feature} = Features.create(project.id, actor, %{title: "Notified feature"})

      {:ok, unread} = deliver_notification(owner.account, project, feature, "unread")
      {:ok, read} = deliver_notification(owner.account, project, feature, "read")
      {:ok, _read} = Notifications.mark_read(owner.account.id, read.id)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        feature_id: feature.id,
        unread_notification_id: unread.id,
        unread_title: unread.title,
        read_notification_id: read.id,
        read_title: read.title
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

    # The same configured hosted project one step further along: its proposal is
    # already approved, so an execution profile version exists, and it holds one
    # current authoritative specification the owner can adopt as the pilot. Both
    # are produced by the real domain — the approval decision and the
    # specification store — rather than inserted.
    defp run(conn, "repository_pilot", _params) do
      owner = new_owner()
      project = registered_project(owner)
      save_owner_profile(project, owner)
      completed = seed_completed_assessment(owner, project)
      profile = approve_profile!(owner, project, completed)
      current = seed_specification(owner, project)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        specification_id: current.specification.id,
        specification_title: current.specification.title,
        revision_id: current.revision.id,
        revision_digest: current.revision.content_digest,
        profile_version: profile.version
      })
    end

    # The global, immutable SDD kit package catalog (specs/15 Task 1). It is
    # not project-scoped, so this scenario seeds no project — only a signed-in
    # owner and two published versions of the same source-and-publisher
    # family, so the browser spec can prove both the ordinary detail view and
    # the read-derived supersession badge.
    defp run(conn, "repository_kits", _params) do
      owner = new_owner()
      older = seed_kit_package("1.0.0")
      newer = seed_kit_package("1.1.0")

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        older_id: older.id,
        older_digest: older.digest,
        older_version: older.version,
        newer_id: newer.id,
        newer_digest: newer.digest,
        newer_version: newer.version
      })
    end

    # One hosted project reachable from every project screen, seeded with a
    # current specification and a feature carrying a recorded run and
    # evidence, plus (per `state`) the owner's personal AI connection state —
    # what specs/12 Task 8's own browser suite needs to prove the panel's
    # ask, citation, uncertainty, failure, retry, and delete behavior through
    # one real turn, with no live model or worker anywhere in the path
    # (`SddOrchestratorWeb.E2EModelCompletionAdapter`, configured only under
    # `E2E_MODE`, answers instead).
    #
    #   * `state=available` (default) — a linked, current connection,
    #     catalog, and quota, so `RuntimeAvailability` reports `:available`.
    #   * `state=unavailable` — a linked but incompatible connection.
    #   * any other value (`state=setup_needed`, or omitted) — no connection.
    defp run(conn, "project_assistant", params) do
      %{project: project, owner: owner} = member_graph()
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}

      current = seed_specification(owner, project)

      {:ok, feature} = Features.create(project.id, actor, %{title: "Reviewed feature"})
      feature = advance(project.id, actor, feature, "ready_for_review")
      %{run: run} = seed_evidence(owner.personal_workspace, project, feature)

      link_assistant_connection(owner.account, params["state"] || "available")

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        feature_id: feature.id,
        run_id: run.id,
        specification_title: current.specification.title
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

    defp approve_profile!(owner, project, completed) do
      authority = {:hosted, owner.account.id}
      {:ok, review} = RepositoryAssessments.profile_review(authority, completed.project_id)

      {:ok, profile} =
        RepositoryAssessments.approve_profile(authority, project.id, review.proposal)

      profile
    end

    # One current authoritative specification the pilot screen can reference. The
    # pilot stores identifiers only, so the document bodies below never leave the
    # specification store.
    defp seed_specification(owner, project) do
      {:ok, current} =
        SpecificationStore.create(
          owner.personal_workspace,
          project.id,
          %{
            id: Ecto.UUID.generate(),
            revision_id: Ecto.UUID.generate(),
            title: @pilot_specification_title,
            documents: %{
              requirements: "# Requirements\n\nAdopt one bounded pilot feature.",
              design: "# Design\n\nReference the specification; never copy it.",
              tasks: "# Tasks\n\n- [ ] Select the pilot"
            }
          },
          actor_ref: "owner"
        )

      current
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
          os_major: "26",
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

    ## Project-assistant personal AI connection (specs/12 Task 8)

    defp link_assistant_connection(_account, "setup_needed"), do: :ok

    defp link_assistant_connection(account, "unavailable") do
      worker = pair_ai_worker(assistant_device_workspace_id())

      {:ok, _connection} =
        PersonalConnections.link_personal_connection(
          account,
          worker,
          %{label: "E2E Codex", provider: "openai_codex", authentication_mode: "chatgpt"},
          adapter: E2EPersonalConnectionAdapter,
          adapter_result:
            {:ok,
             %{
               worker_profile_ref: "e2e-profile-#{worker.id}",
               provider: "openai_codex",
               authentication_mode: "chatgpt",
               availability: "incompatible",
               adapter_compatibility_version: "connection/1"
             }}
        )

      :ok
    end

    defp link_assistant_connection(account, _available) do
      now = DateTime.utc_now()
      worker = pair_ai_worker(assistant_device_workspace_id())

      {:ok, connection} =
        PersonalConnections.link_personal_connection(
          account,
          worker,
          %{label: "E2E Codex", provider: "openai_codex", authentication_mode: "chatgpt"},
          adapter: E2EPersonalConnectionAdapter
        )

      {:ok, _catalog} =
        ModelCatalogs.refresh(account, connection.id,
          adapter: E2EModelCatalogAdapter,
          adapter_result: {:ok, assistant_catalog_result(now)},
          now: now,
          ttl_seconds: 3600
        )

      {:ok, _quota} =
        Quotas.refresh(account, connection.id,
          adapter: E2EQuotaAdapter,
          adapter_result: {:ok, assistant_quota_result(now)},
          now: now,
          ttl_seconds: 3600
        )

      :ok
    end

    defp assistant_device_workspace_id do
      {:ok, workspace} = Devices.establish_workspace()
      workspace.id
    end

    defp assistant_catalog_result(now) do
      %{
        status: "enumerated",
        provider: "openai_codex",
        source: "official_client",
        source_method: "model/list",
        source_version: "codex-cli e2e|schema:" <> String.duplicate("0", 64),
        retrieved_at: now,
        models: [
          %{
            id: "catalog-e2e-model",
            model: "e2e-model",
            display_name: "E2E Model",
            current: true,
            default: true,
            default_reasoning_effort: "medium",
            supported_reasoning_efforts: [
              %{reasoning_effort: "medium", description: "Authenticated medium reasoning"}
            ]
          }
        ]
      }
    end

    defp assistant_quota_result(now) do
      %{
        status: "reported",
        provider: "openai_codex",
        authentication_mode: "chatgpt",
        source: "official_client",
        source_methods: ["account/rateLimits/read", "account/usage/read"],
        source_version: "codex-cli e2e|schema:" <> String.duplicate("0", 64),
        retrieved_at: now,
        buckets: [
          %{
            id: "general",
            scope: "general",
            model: nil,
            display_name: "General Codex",
            primary_window: %{
              used_percent: 10,
              resets_at: DateTime.add(now, 3600, :second),
              duration_minutes: 300,
              unknown_fields: []
            },
            secondary_window: nil,
            credits: %{has_credits: true, unlimited: false, balance: "10.00", unknown_fields: []},
            paid_continuation: "unknown",
            spend_control: nil,
            spend_control_reached: nil,
            limit_reached_reason: nil,
            unknown_fields: [
              "secondary_window",
              "paid_continuation",
              "spend_control",
              "spend_control_reached",
              "limit_reached_reason"
            ]
          }
        ],
        reset_credits: %{available_count: 1, unknown_fields: []},
        token_activity: %{
          lifetime_tokens: 0,
          peak_daily_tokens: 0,
          current_streak_days: 0,
          longest_streak_days: 0,
          longest_running_turn_seconds: 0,
          unknown_fields: []
        },
        unknown_fields: ["provider_billing"]
      }
    end

    # One immutable kit package version through the real publish boundary — no
    # disk or network I/O, and the tiny script content is never executed.
    defp seed_kit_package(version) do
      attrs = %{
        source: "https://github.com/octo/sdd-kit",
        publisher: "octo",
        version: version,
        license: "MIT",
        provenance: %{
          ref_type: "commit",
          ref: "0123456789abcdef0123456789abcdef01234567",
          repository: "octo/sdd-kit"
        },
        supported_adapters: ["claude_code"],
        required_permissions: ["repository:read"],
        scripts: ["scripts/check.sh"]
      }

      # The digest is content-addressed (`RepositoryKitPackage.digest_of/1`),
      # so each version's files must differ or the second publish would
      # collide on the unique digest index instead of producing a distinct
      # superseded/superseding pair.
      files = [
        %{path: "SKILL.md", content: "# skill #{version}\n", executable: false},
        %{path: "scripts/check.sh", content: "#!/bin/sh\necho ok\n", executable: true}
      ]

      {:ok, package} = RepositoryKits.publish_package(attrs, files)
      package
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

    # A hosted project whose repository provider is local, holding the portable
    # identity the selected machine must prove exactly.
    defp new_local_repository_project(owner, repository_id) do
      %Project{}
      |> Project.changeset(%{
        name: @project_name,
        workspace_id: owner.personal_workspace.id,
        storage_mode: "hosted",
        repository_provider: "local",
        canonical_repository_id: repository_id
      })
      |> Repo.insert!()
    end

    # The folder the worker stand-in's picker opens, which is this server's own
    # working copy unless the environment names another.
    defp stub_repository do
      Application.get_env(:sdd_orchestrator, :device_worker_stub_folder) || File.cwd!()
    end

    # One active, reachable worker paired to this machine's device workspace.
    defp pair_available_worker do
      {:ok, workspace} = Devices.establish_workspace()
      {:ok, %{code: code}} = Pairing.start_pairing(workspace.id)
      policy = SddOrchestrator.Devices.WorkerDiscovery.compatibility_policy()

      {:ok, %{worker: worker}} =
        Pairing.complete_pairing(code, %{
          os_family: policy.os_family,
          os_major: List.last(policy.os_majors),
          protocol_version: List.first(policy.protocol_versions),
          app_version: "0.0.0-e2e"
        })

      {:ok, worker} = Pairing.mark_seen(worker)
      worker
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

    # A `delivery.` notification addressed the same way the real projector
    # addresses one: to the recipient's own application account, carrying only
    # the minimized presentation fields and the feature's safe in-product link.
    defp deliver_notification(account, project, feature, suffix) do
      Notifications.deliver(%{
        account_id: account.id,
        event_type: "delivery.run_blocked",
        subject_ref: "e2e-notification-#{suffix}-#{unique_suffix()}",
        event_version: 1,
        title: "Notification #{suffix}",
        body: "A feature is waiting on an answer before development continues.",
        project_label: project.name,
        link_path: "/projects/#{project.id}/features/#{feature.id}",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

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
