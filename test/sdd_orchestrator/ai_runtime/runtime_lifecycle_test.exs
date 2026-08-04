defmodule SddOrchestrator.AIRuntime.RuntimeLifecycleTest do
  @moduledoc """
  Task 14 proof that a pinned runtime configuration and its ceiling ledger are
  kept only for their approved purpose and lifetime.

  Covers the active and detached accountability windows and their exact
  boundaries, connection removal detaching the opaque reference instead of
  destroying the account of the run, a resumable pause surviving a sweep, the
  project and conversation deletion handoff, verified access with its minimized
  allowlist, the correction refusal at both the rights boundary and the
  database, restriction, objection, erasure, service termination, derived-copy
  and processor propagation with the encrypted-backup handoff, and idempotent
  convergence under the sweep's own advisory lock.

  Advisory-locked sweeps are session-scoped, so this proof runs serially.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    PersonalAIConnection,
    PersonalConnectionRevocations,
    PersonalConnections,
    RuntimeCostLedger,
    RuntimeCosts,
    RuntimeSessions
  }

  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.Portability.PackageProvenance
  alias SddOrchestrator.Privacy.{DeploymentPrivacyProfile, Retention, RetentionPruner, Rights}
  alias SddOrchestrator.ProjectsFixtures

  @now ~U[2026-08-03 12:00:00Z]
  @day 24 * 60 * 60
  @accountability_window 90 * @day
  @detached_window 30 * @day
  @worker_profile_ref "profile-task14-secret"
  @confirming [adapter: PersonalConnectionAdapterDouble]

  @session_export_keys ~w(
    authentication_mode catalog_expires_at catalog_retrieved_at catalog_snapshot_ref
    catalog_source catalog_source_method catalog_source_version configuration_version
    connection_id consumer_kind consumer_ref id inserted_at model opt_ins pinned_at
    provider reasoning_effort spending_ceiling_amount spending_ceiling_currency
  )a

  @ledger_export_keys ~w(
    ceiling currency id input_unit_price inserted_at max_input_tokens max_output_tokens
    observed_amount output_unit_price outstanding_reservations pause_reason paused
    paused_at price_expires_at price_published_at price_source price_version
    reserved_amount session_id
  )a

  setup do
    context =
      runtime_cost_context_fixture(%{
        now: @now,
        ceiling: "0.30",
        worker_profile_ref: @worker_profile_ref
      })

    Map.put(context, :ledger, runtime_cost_ledger_fixture(context, %{now: @now}))
  end

  describe "accountability window" do
    test "an active session and its ledger are retained for the whole window", context do
      just_before = DateTime.add(@now, @accountability_window - 1, :second)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_all(just_before)

      assert {:ok, session} =
               RuntimeSessions.get_session(context.account, context.session.session_id)

      assert session.model == context.session.model
      assert session.pinned_at == @now

      assert {:ok, _ledger} =
               RuntimeCosts.get_ledger(context.account, context.session.session_id)
    end

    test "the session and its ledger are deleted at the boundary and stay deleted", context do
      boundary = DateTime.add(@now, @accountability_window, :second)

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 1} =
               Retention.prune_all(boundary)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0

      assert {:error, :not_found} =
               RuntimeSessions.get_session(context.account, context.session.session_id)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_all(boundary)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_ai_runtime_sessions(boundary)
    end

    test "a resumable pause is not a deletion trigger and still resumes", context do
      assert {:ok, %{ledger: full}} = reserve(context, "turn-1")
      assert Decimal.equal?(full.remaining, 0)
      assert {:pause, :insufficient_capacity} = reserve(context, "turn-2")

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_all(DateTime.add(@now, @accountability_window - 1, :second))

      assert {:ok, paused} = RuntimeCosts.get_ledger(context.account, context.session.session_id)
      assert paused.paused == true
      assert paused.pause_reason == :insufficient_capacity
      assert Enum.map(paused.outstanding, & &1.idempotency_key) == ["turn-1"]

      assert {:ok, pinned} =
               RuntimeSessions.get_session(context.account, context.session.session_id)

      assert pinned.opt_ins == context.session.opt_ins

      assert {:ok, _released} =
               RuntimeCosts.release(context.account, context.session.session_id, "turn-1")

      assert {:ok, %{ledger: resumed}} = reserve(context, "turn-2")
      assert resumed.paused == false
    end
  end

  describe "personal connection removal" do
    test "removal detaches the opaque reference and keeps the account of the run", context do
      remove_connection(context)

      assert Repo.get(PersonalAIConnection, context.connection.id) == nil

      assert %AIRuntimeSession{} =
               session = Repo.get(AIRuntimeSession, context.session.session_id)

      assert session.connection_id == nil
      assert session.model == context.session.model
      assert session.pinned_at == @now
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1
    end

    test "a detached session serves the shorter window while an attached one does not",
         context do
      attached =
        runtime_cost_context_fixture(%{now: @now, ceiling: "0.30", consumer_ref: "run-attached"})

      runtime_cost_ledger_fixture(attached, %{now: @now})
      remove_connection(context)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_all(DateTime.add(@now, @detached_window - 1, :second))

      assert Repo.aggregate(AIRuntimeSession, :count) == 2

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 1} =
               Retention.prune_all(DateTime.add(@now, @detached_window, :second))

      assert Repo.get(AIRuntimeSession, context.session.session_id) == nil

      assert {:ok, _still_accounted} =
               RuntimeSessions.get_session(attached.account, attached.session.session_id)

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 1} =
               Retention.prune_all(DateTime.add(@now, @accountability_window, :second))

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end
  end

  describe "consumer deletion handoff" do
    test "deleting the owning project retires its sessions and ledgers", context do
      %{workspace: workspace, project: project} = restored_project(context)
      project_context = pin_consumer(context, :working_agent, project.id)
      runtime_cost_ledger_fixture(project_context, %{now: @now})

      assert Repo.aggregate(AIRuntimeSession, :count) == 2
      assert Repo.aggregate(RuntimeCostLedger, :count) == 2

      assert {:ok, erasure} = Rights.erase_portability_project(workspace, project.id)
      assert erasure.action == :erasure
      assert erasure.runtime_records.sessions == 1
      assert erasure.runtime_records.cost_ledgers == 1

      assert Repo.get(AIRuntimeSession, project_context.session.session_id) == nil
      assert Repo.aggregate(AIRuntimeSession, :count) == 1
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1

      assert {:ok, _unaffected} =
               RuntimeSessions.get_session(context.account, context.session.session_id)
    end

    test "retiring a deleted conversation removes only that consumer and converges", context do
      conversation = pin_consumer(context, :support_assistant, "conversation-1")
      other = pin_consumer(context, :support_assistant, "conversation-2")

      assert {:ok, retired} =
               Rights.retire_runtime_consumers(context.account, [
                 {:support_assistant, "conversation-1"}
               ])

      assert retired.sessions == 1
      assert retired.cost_ledgers == 0
      assert Repo.get(AIRuntimeSession, conversation.session.session_id) == nil
      assert Repo.get(AIRuntimeSession, other.session.session_id)

      assert {:ok, repeated} =
               Rights.retire_runtime_consumers(context.account, [
                 {:support_assistant, "conversation-1"}
               ])

      assert repeated.sessions == 0
      assert repeated.cost_ledgers == 0
    end

    test "an unnamed, foreign, or unknown consumer retires nothing", context do
      assert {:ok, none} = Rights.retire_runtime_consumers(context.account, [])
      assert none.sessions == 0

      assert {:ok, invalid} =
               Rights.retire_runtime_consumers(context.account, [{:unknown_kind, "run-1"}])

      assert invalid.sessions == 0

      foreign = account_fixture()

      assert {:ok, scoped} =
               Rights.retire_runtime_consumers(foreign, [
                 {:working_agent, context.session.consumer_ref}
               ])

      assert scoped.sessions == 0

      assert {:ok, _untouched} =
               RuntimeSessions.get_session(context.account, context.session.session_id)
    end

    test "the retirement handoff carries the deletion propagation contract", context do
      assert {:ok, retired} =
               Rights.retire_runtime_consumers(context.account, [
                 {:working_agent, context.session.consumer_ref}
               ])

      assert retired.sessions == 1
      assert retired.cost_ledgers == 1
      assert retired.propagation.primary_boundary == :hosted
      assert retired.propagation.primary_store == :deleted

      assert %{processor: :hosting_database, action: :delete} in retired.propagation.processors

      assert %{record: :current_project, action: :delete} in retired.propagation.derived_records

      assert retired.propagation.encrypted_backups ==
               DeploymentPrivacyProfile.backup_handoff(:erasure)
    end
  end

  describe "rights integration" do
    test "the access export reports both entities with only their minimized fields",
         context do
      assert {:ok, export} = Rights.export_account(context.account.id)

      assert [session] = export.ai_runtime_sessions
      assert Enum.sort(Map.keys(session)) == Enum.sort(@session_export_keys)
      assert session.id == context.session.session_id
      assert session.connection_id == context.connection.id
      assert session.consumer_kind == "working_agent"
      assert session.model == "codex-test-model"
      assert session.authentication_mode == "api_key"
      assert session.spending_ceiling_currency == "USD"
      assert session.opt_ins == []
      assert session.pinned_at == @now

      assert [ledger] = export.runtime_cost_ledgers
      assert Enum.sort(Map.keys(ledger)) == Enum.sort(@ledger_export_keys)
      assert ledger.session_id == context.session.session_id
      assert ledger.currency == "USD"
      assert ledger.price_version == "2026-08-01"
      assert ledger.paused == false
      assert ledger.outstanding_reservations == []

      refute inspect(export) =~ @worker_profile_ref
    end

    test "the export allowlist covers every stored field except the account link", _context do
      assert Enum.sort(@session_export_keys) ==
               AIRuntimeSession.__schema__(:fields)
               |> Kernel.--([:account_id, :updated_at])
               |> Enum.sort()

      assert Enum.sort(@ledger_export_keys) ==
               RuntimeCostLedger.__schema__(:fields)
               |> Kernel.--([:account_id, :updated_at])
               |> Enum.sort()
    end

    test "the access export names both entities even when nothing is held", _context do
      account = account_fixture()

      assert {:ok, export} = Rights.export_account(account.id)
      assert export.ai_runtime_sessions == []
      assert export.runtime_cost_ledgers == []
    end

    test "a detached session is still exported as the account of a run that happened",
         context do
      remove_connection(context)

      assert {:ok, export} = Rights.export_account(context.account.id)
      assert [session] = export.ai_runtime_sessions
      assert session.connection_id == nil
      assert session.model == "codex-test-model"
      assert [_ledger] = export.runtime_cost_ledgers
    end

    test "correction is refused at the boundary and by the database", context do
      session_id = context.session.session_id

      assert {:ok, refusal} =
               Rights.assess_runtime_session_request(context.account, session_id, :correction)

      assert refusal.action == :correction
      assert refusal.session_id == session_id
      assert refusal.disposition == :refused_immutable_accountability_evidence
      assert :erasure in refusal.available_actions
      assert refusal.propagation.primary_boundary == :hosted
      refute Map.has_key?(refusal.propagation, :primary_store)

      assert_raise Ecto.ConstraintError, ~r/ai_runtime_sessions_immutable_configuration/, fn ->
        AIRuntimeSession
        |> Repo.get!(session_id)
        |> Ecto.Changeset.change(%{model: "corrected-model"})
        |> Repo.update!()
      end

      assert Repo.get!(AIRuntimeSession, session_id).model == "codex-test-model"
    end

    test "restriction and objection require a verified operator decision", context do
      for action <- [:restriction, :objection] do
        assert {:ok, assessment} =
                 Rights.assess_runtime_session_request(
                   context.account,
                   context.session.session_id,
                   action
                 )

        assert assessment.action == action
        assert assessment.disposition == :verified_operator_assessment_required
        assert assessment.propagation.primary_store == :pending_verified_operator_decision

        assert %{processor: :hosting_database, action: :apply_operator_decision} in assessment.propagation.processors

        assert assessment.propagation.encrypted_backups ==
                 DeploymentPrivacyProfile.backup_handoff(:apply_operator_decision)
      end
    end

    test "a request for an unknown or foreign session is not found", context do
      foreign = account_fixture()

      assert {:error, :not_found} =
               Rights.assess_runtime_session_request(
                 foreign,
                 context.session.session_id,
                 :restriction
               )

      assert {:error, :not_found} =
               Rights.assess_runtime_session_request(context.account, "not-a-uuid", :correction)

      assert {:error, :not_found} =
               Rights.assess_runtime_session_request(
                 context.account,
                 context.session.session_id,
                 :retention
               )
    end

    test "account erasure leaves no session or ledger behind", context do
      other = runtime_cost_context_fixture(%{now: @now, ceiling: "0.30"})
      runtime_cost_ledger_fixture(other, %{now: @now})

      assert {:ok, _erasure} =
               Rights.erase_account(context.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(AIRuntimeSession, :count) == 1
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1

      assert {:ok, _erasure} = Rights.erase_account(other.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end

    test "erasing a detached session's account still leaves nothing behind", context do
      remove_connection(context)

      assert {:ok, _erasure} =
               Rights.erase_account(context.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end

    test "service termination reports the account of what ran and retains it", context do
      other = runtime_cost_context_fixture(%{now: @now, ceiling: "0.30"})

      assert {:ok, termination} =
               Rights.terminate_personal_ai_service(
                 [at: @now, account: context.account] ++ @confirming
               )

      assert termination.personal_ai_runtime == %{
               sessions: 1,
               cost_ledgers: 1,
               observations: 0,
               disposition: :retained_for_project_accountability
             }

      assert {:ok, _retained} =
               RuntimeSessions.get_session(context.account, context.session.session_id)

      assert {:ok, _untouched} =
               RuntimeSessions.get_session(other.account, other.session.session_id)

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 1} =
               Retention.prune_all(DateTime.add(@now, @detached_window, :second))

      assert Repo.get(AIRuntimeSession, context.session.session_id) == nil
      assert Repo.get(AIRuntimeSession, other.session.session_id)
    end
  end

  describe "supervised sweep" do
    test "the sweep contends on its own advisory lock key", _context do
      key = Retention.runtime_advisory_lock_key()

      assert key > 0
      refute key == Retention.snapshot_advisory_lock_key()
      refute key == PersonalConnectionRevocations.advisory_lock_key()
      refute key == RetentionPruner.advisory_lock_key()
    end

    test "a contended sweep yields, deletes nothing, and the next pass converges", _context do
      due = DateTime.add(@now, @accountability_window, :second)
      holder = start_lock_holder()

      assert :locked = Retention.prune_ai_runtime_sessions(due)
      assert Repo.aggregate(AIRuntimeSession, :count) == 1

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_all(due)

      assert Repo.aggregate(AIRuntimeSession, :count) == 1
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1

      release_lock_holder(holder)

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 1} =
               Retention.prune_ai_runtime_sessions(due)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_ai_runtime_sessions(due)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end
  end

  defp reserve(context, idempotency_key) do
    RuntimeCosts.reserve(
      context.account,
      context.session.session_id,
      runtime_cost_reserve_request(%{idempotency_key: idempotency_key}),
      now: @now,
      snapshots: official_price_snapshots()
    )
  end

  # The realistic removal path: the owner revokes, the worker confirms, and the
  # opaque reference is deleted once its own short lifetime has passed.
  defp remove_connection(context) do
    assert {:ok, acknowledged} =
             PersonalConnections.request_revocation(
               context.account,
               context.connection.id,
               [at: @now] ++ @confirming
             )

    assert acknowledged.revocation_state == "acknowledged"

    assert %{revoked_personal_ai_connections: 1} =
             Retention.prune_all(acknowledged.deletion_scheduled_at)

    acknowledged
  end

  defp pin_consumer(context, consumer, consumer_ref) do
    session =
      ai_runtime_session_fixture(context, %{
        now: @now,
        consumer: consumer,
        consumer_ref: consumer_ref
      })

    Map.put(context, :session, session)
  end

  defp restored_project(context) do
    workspace = ProjectsFixtures.workspace_fixture(context.account)
    project = ProjectsFixtures.project_fixture(workspace)

    Repo.insert!(
      PackageProvenance.create_changeset(%PackageProvenance{}, %{
        project_id: project.id,
        payload_schema_version: 1,
        restored_at: @now
      })
    )

    %{workspace: workspace, project: project}
  end

  # The sweep's lock is session-scoped and re-entrant within one session, so the
  # shared sandbox connection cannot stand in for a competing instance.
  defp start_lock_holder do
    {:ok, holder} = Postgrex.start_link(postgrex_options())
    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [
               Retention.runtime_advisory_lock_key()
             ])

    holder
  end

  defp release_lock_holder(holder) do
    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [
               Retention.runtime_advisory_lock_key()
             ])
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
