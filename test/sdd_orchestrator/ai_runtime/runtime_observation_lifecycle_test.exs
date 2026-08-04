defmodule SddOrchestrator.AIRuntime.RuntimeObservationLifecycleTest do
  @moduledoc """
  Task 17 proof that an agent runtime observation is kept only for its bounded
  safety and accountability purpose, and carries the same verified rights
  handling the pinned session and its ceiling ledger already do.

  Covers the operational window and its exact boundary, the access that is
  genuinely lost when the trail expires and is projected as unknown rather than
  as zero for both audiences, the project and conversation deletion handoff, the
  session cascade, verified access with its schema-derived allowlist, the
  correction refusal at the rights boundary and in the entity itself, erasure,
  restriction, objection, derived-copy and processor propagation with the
  encrypted-backup handoff, the absence of any surviving cached or indexed copy,
  service termination, cross-account isolation, and idempotent convergence under
  the sweep's own advisory lock.

  Advisory-locked sweeps are session-scoped, so this proof runs serially.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    PersonalConnectionRevocations,
    RuntimeCostLedger,
    RuntimeCosts,
    RuntimeObservations,
    RuntimeProjections,
    RuntimeSessions
  }

  alias SddOrchestrator.ObservationAdapterDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.Privacy.{DeploymentPrivacyProfile, Retention, RetentionPruner, Rights}

  @now ~U[2026-08-03 12:00:00Z]
  @observed_at ~U[2026-08-03 12:00:30Z]
  @ingested_at ~U[2026-08-03 12:05:00Z]
  @day 24 * 60 * 60
  @observation_window 30 * @day
  @accountability_window 90 * @day
  @worker_profile_ref "profile-task17-secret"
  @confirming [adapter: PersonalConnectionAdapterDouble]

  # The observation trail is due long before the account of the run it belongs
  # to, so this instant deletes the trail and leaves the session and ledger.
  @observations_due DateTime.add(@observed_at, @observation_window, :second)

  # The only two columns the access copy withholds: the account link the copy is
  # already scoped by, and the row's own update metadata.
  @withheld_from_access_copy [:account_id, :updated_at]

  # Every index the table actually carries, so a search index holding a second
  # copy of an observation could not be added unnoticed.
  @declared_indexes [
    "agent_runtime_observations_account_id_session_id_observed_at_in",
    "agent_runtime_observations_pkey",
    "agent_runtime_observations_session_event_key_index",
    "agent_runtime_observations_session_sequence_index"
  ]

  setup do
    context =
      runtime_observation_context_fixture(%{
        now: @now,
        authentication_mode: "api_key",
        worker_profile_ref: @worker_profile_ref
      })

    context
    |> Map.put(:ledger, runtime_cost_ledger_fixture(context, %{now: @now}))
    |> Map.put(:observation, runtime_observation_fixture(context, %{now: @ingested_at}))
  end

  describe "operational window" do
    test "an observation is retained for its whole window and deleted at the boundary",
         context do
      just_before = DateTime.add(@observed_at, @observation_window - 1, :second)

      assert %{expired_agent_runtime_observations: 0} = Retention.prune_all(just_before)
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1

      assert %{expired_agent_runtime_observations: 1} = Retention.prune_all(@observations_due)
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 0

      # The account of what the run executed under, and the cost reconciled
      # against its ceiling, serve a longer window and are untouched here.
      assert {:ok, session} =
               RuntimeSessions.get_session(context.account, context.session.session_id)

      assert session.pinned_at == @now
      assert {:ok, _ledger} = RuntimeCosts.get_ledger(context.account, context.session.session_id)
      assert Repo.aggregate(AIRuntimeSession, :count) == 1
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1
    end
  end

  describe "access after the window" do
    test "the owner reads the expired run as unknown rather than as zero", context do
      assert %{expired_agent_runtime_observations: 1} = Retention.prune_all(@observations_due)

      assert {:ok, projection} = owner(context)

      assert projection.session_id == context.session.session_id
      assert projection.observations == []
      assert projection.usage.elapsed == %{seconds: nil, source: :unknown}
      assert projection.usage.tokens == %{input: nil, output: nil, total: nil, source: :unknown}

      assert projection.usage.estimated_cost == %{
               amount: nil,
               currency: nil,
               basis: nil,
               source: :unknown
             }

      assert projection.availability == %{state: :unknown, pause_reason: nil, source: :unknown}

      # Absence is absence. No expired value comes back as a zero, and no label
      # still claims the value was observed.
      refute projection.usage.elapsed.seconds == 0
      refute projection.usage.tokens.total == 0
      refute projection.usage.estimated_cost.amount == Decimal.new(0)
      refute projection.usage.elapsed.source == :worker_observed
      refute projection.usage.tokens.source == :worker_observed
      refute projection.usage.estimated_cost.source == :local_estimate
      refute projection.availability.source == :provider_fact
    end

    test "a current participant reads the same expired run as unknown", context do
      %{project: project, participant_actor: actor} = project_scope()

      assert {:ok, before_sweep} = participant(project, actor, context)
      assert before_sweep.usage.tokens.total == 1_500

      assert %{expired_agent_runtime_observations: 1} = Retention.prune_all(@observations_due)

      assert {:ok, projection} = participant(project, actor, context)

      assert projection.session_id == context.session.session_id
      assert projection.observations == []
      assert projection.usage.elapsed == %{seconds: nil, source: :unknown}
      assert projection.usage.tokens == %{input: nil, output: nil, total: nil, source: :unknown}
      assert projection.availability == %{state: :unknown, pause_reason: nil, source: :unknown}

      refute projection.usage.tokens.total == 0
      refute projection.usage.elapsed.seconds == 0
    end
  end

  describe "consumer deletion handoff" do
    test "retiring a deleted project removes that run's observations and reports them",
         context do
      unrelated = observed_session(context, :working_agent, "run-unrelated")

      assert {:ok, retired} =
               Rights.retire_runtime_consumers(context.account, [
                 {:working_agent, context.session.consumer_ref}
               ])

      assert retired.sessions == 1
      assert retired.cost_ledgers == 1
      assert retired.observations == 1

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1
      assert observation_count(unrelated) == 1
      assert Repo.get(AIRuntimeSession, unrelated.session.session_id)
    end

    test "retiring a deleted conversation removes that run's observations and converges",
         context do
      conversation = observed_session(context, :support_assistant, "conversation-1")
      other = observed_session(context, :support_assistant, "conversation-2")

      assert {:ok, retired} =
               Rights.retire_runtime_consumers(context.account, [
                 {:support_assistant, "conversation-1"}
               ])

      assert retired.sessions == 1
      assert retired.observations == 1
      assert observation_count(conversation) == 0
      assert observation_count(other) == 1

      assert {:ok, repeated} =
               Rights.retire_runtime_consumers(context.account, [
                 {:support_assistant, "conversation-1"}
               ])

      assert repeated.sessions == 0
      assert repeated.observations == 0
      assert observation_count(other) == 1
    end

    test "the retirement handoff carries the deletion propagation contract", context do
      assert {:ok, retired} =
               Rights.retire_runtime_consumers(context.account, [
                 {:working_agent, context.session.consumer_ref}
               ])

      assert retired.observations == 1
      assert retired.propagation.primary_boundary == :hosted
      assert retired.propagation.primary_store == :deleted

      assert %{processor: :hosting_database, action: :delete} in retired.propagation.processors

      assert %{record: :current_project, action: :delete} in retired.propagation.derived_records

      assert retired.propagation.encrypted_backups ==
               DeploymentPrivacyProfile.backup_handoff(:erasure)
    end

    test "deleting the session row cascades its observations away", context do
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1

      assert {1, _returned} =
               Repo.delete_all(
                 from session in AIRuntimeSession,
                   where: session.id == ^context.session.session_id
               )

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 0
    end
  end

  describe "access and portability" do
    test "the export reports every stored field with its labels decoded", context do
      foreign = observed_account()

      assert {:ok, export} = Rights.export_account(context.account.id)

      assert [observation] = export.agent_runtime_observations

      # The allowlist is derived from the schema, so a column added later cannot
      # escape the access copy unnoticed.
      assert Enum.sort(Map.keys(observation)) ==
               AgentRuntimeObservation.__schema__(:fields)
               |> Kernel.--(@withheld_from_access_copy)
               |> Enum.sort()

      for withheld <- @withheld_from_access_copy do
        refute Map.has_key?(observation, withheld)
      end

      assert observation.id == context.observation.observation_id
      assert observation.session_id == context.session.session_id
      assert observation.sequence == 1
      assert observation.observed_at == @observed_at
      assert observation.elapsed_seconds == 30
      assert observation.elapsed_source == "worker_observed"
      assert observation.total_tokens == 1_500
      assert observation.tokens_source == "worker_observed"
      assert observation.estimated_cost_currency == "USD"
      assert observation.cost_source == "local_estimate"
      assert observation.status == "available"
      assert observation.pause_reason == nil
      assert observation.unknown_fields == []

      # The basis and the quota references are readable values rather than raw
      # stored jsonb, and the estimate is labelled so it cannot be read as a
      # provider invoice.
      assert observation.estimated_cost_basis.price_version == "2026-08-01"
      assert observation.estimated_cost_basis.model == "codex-test-model"
      assert observation.estimated_cost_basis.input_tokens == 1_200

      assert Decimal.equal?(
               observation.estimated_cost_basis.input_unit_price,
               Decimal.new("2.00")
             )

      assert observation.quota_refs == [%{id: "general", scope: "general", model: nil}]
      assert observation.quota_source == "provider_fact"

      # Another account's trail never crosses into this copy, and the
      # worker-local profile reference is nowhere in it.
      refute inspect(export) =~ foreign.observation.event_key
      refute inspect(export) =~ @worker_profile_ref
    end

    test "the export names the entity even when nothing is held", _context do
      account = account_fixture()

      assert {:ok, export} = Rights.export_account(account.id)
      assert export.agent_runtime_observations == []
    end
  end

  describe "rights disposition" do
    test "correction is refused at the boundary, in the entity, and at ingest", context do
      observation_id = context.observation.observation_id

      assert {:ok, refusal} =
               Rights.assess_runtime_observation_request(
                 context.account,
                 observation_id,
                 :correction
               )

      assert refusal.action == :correction
      assert refusal.observation_id == observation_id
      assert refusal.disposition == :refused_immutable_operational_record
      assert refusal.reason == :observation_is_the_record_of_what_was_observed

      assert refusal.available_actions == [
               :access,
               :portability,
               :erasure,
               :restriction,
               :objection
             ]

      assert refusal.propagation.primary_boundary == :hosted
      refute Map.has_key?(refusal.propagation, :primary_store)

      # The refusal is structural, not a policy the entity could be talked out
      # of: there is no update path to reach the row with.
      assert Code.ensure_loaded?(AgentRuntimeObservation)
      assert function_exported?(AgentRuntimeObservation, :create_changeset, 2)
      refute function_exported?(AgentRuntimeObservation, :update_changeset, 2)
      refute function_exported?(AgentRuntimeObservation, :changeset, 2)

      # Restating the same event with different facts is refused rather than
      # applied, so history cannot be corrected through the append boundary.
      assert {:error, :duplicate_event} =
               RuntimeObservations.ingest(context.account, context.session.session_id,
                 adapter: ObservationAdapterDouble,
                 adapter_result:
                   {:ok,
                    observation_adapter_result(%{
                      event_key: context.observation.event_key,
                      sequence: 1,
                      tokens: %{input: 10, output: 5, total: 15, source: "worker_observed"},
                      estimated_cost: %{
                        amount: nil,
                        currency: nil,
                        basis: nil,
                        source: "unknown"
                      },
                      unknown_fields: ["estimated_cost"]
                    })},
                 now: @ingested_at
               )

      assert Repo.get!(AgentRuntimeObservation, observation_id).total_tokens == 1_500
    end

    test "restriction and objection require a verified operator decision", context do
      observation_id = context.observation.observation_id

      for action <- [:restriction, :objection] do
        assert {:ok, assessment} =
                 Rights.assess_runtime_observation_request(
                   context.account,
                   observation_id,
                   action
                 )

        assert assessment.action == action
        assert assessment.observation_id == observation_id
        assert assessment.disposition == :verified_operator_assessment_required
        assert assessment.propagation.primary_store == :pending_verified_operator_decision

        assert %{processor: :hosting_database, action: :apply_operator_decision} in assessment.propagation.processors

        assert %{record: :current_project, action: :apply_operator_decision} in assessment.propagation.derived_records

        assert assessment.propagation.encrypted_backups ==
                 DeploymentPrivacyProfile.backup_handoff(:apply_operator_decision)
      end
    end

    test "a foreign, unknown, or malformed observation is not found", context do
      observation_id = context.observation.observation_id
      foreign = account_fixture()

      assert {:error, :not_found} =
               Rights.assess_runtime_observation_request(foreign, observation_id, :correction)

      assert {:error, :not_found} =
               Rights.assess_runtime_observation_request(
                 context.account,
                 Ecto.UUID.generate(),
                 :restriction
               )

      assert {:error, :not_found} =
               Rights.assess_runtime_observation_request(
                 context.account,
                 "not-a-uuid",
                 :objection
               )

      assert {:error, :not_found} =
               Rights.assess_runtime_observation_request(
                 context.account,
                 observation_id,
                 :retention
               )
    end

    test "account erasure leaves no observation behind", context do
      other = observed_account()

      assert {:ok, _erasure} =
               Rights.erase_account(context.account.id, [at: @now] ++ @confirming)

      assert observation_count(other) == 1
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1

      assert {:ok, _erasure} = Rights.erase_account(other.account.id, [at: @now] ++ @confirming)

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 0
    end

    test "service termination retains the trail of work that already ran", context do
      other = observed_account()

      assert {:ok, termination} =
               Rights.terminate_personal_ai_service(
                 [at: @now, account: context.account] ++ @confirming
               )

      assert termination.personal_ai_runtime.observations == 1
      assert termination.personal_ai_runtime.disposition == :retained_for_project_accountability

      # Termination is a revocation of every connection at once, not an erasure
      # request, so the record of what already happened survives it.
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 2
      assert observation_count(context) == 1
      assert observation_count(other) == 1

      assert {:ok, [_still_readable]} =
               RuntimeObservations.list_observations(
                 context.account,
                 context.session.session_id
               )
    end
  end

  describe "no surviving copy" do
    test "the table carries no index that could hold a second copy", _context do
      indexes =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = $1",
          ["agent_runtime_observations"]
        )

      assert indexes.rows |> List.flatten() |> Enum.sort() == Enum.sort(@declared_indexes)
    end

    test "every read path reports absence rather than a memoized value", context do
      account = context.account
      session_id = context.session.session_id

      assert %{expired_agent_runtime_observations: 1} = Retention.prune_all(@observations_due)

      assert {:ok, []} = RuntimeObservations.list_observations(account, session_id)
      assert {:error, :not_found} = RuntimeObservations.latest_observation(account, session_id)

      assert {:ok, first} = owner(context)
      assert {:ok, second} = owner(context)

      assert first == second
      assert first.observations == []
      assert first.usage.tokens.source == :unknown
    end
  end

  describe "supervised sweep" do
    test "the sweep contends on its own advisory lock key", _context do
      key = Retention.observation_advisory_lock_key()

      assert key > 0
      refute key == Retention.snapshot_advisory_lock_key()
      refute key == Retention.runtime_advisory_lock_key()
      refute key == RetentionPruner.advisory_lock_key()
      refute key == PersonalConnectionRevocations.advisory_lock_key()
    end

    test "a contended sweep yields, deletes nothing, and the next pass converges", _context do
      holder = start_lock_holder()

      assert :locked = Retention.prune_ai_runtime_observations(@observations_due)
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1

      assert %{expired_agent_runtime_observations: 0} = Retention.prune_all(@observations_due)
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1

      release_lock_holder(holder)

      assert %{expired_agent_runtime_observations: 1} =
               Retention.prune_ai_runtime_observations(@observations_due)

      assert %{expired_agent_runtime_observations: 0} =
               Retention.prune_ai_runtime_observations(@observations_due)

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 0
    end

    test "the whole pruner counts only what the observation sweep itself removed", context do
      session_due = DateTime.add(@now, @accountability_window, :second)

      # A second run pinned late enough to survive this pass, whose own trail is
      # nonetheless past its shorter window.
      later_pin = DateTime.add(session_due, -60 * @day, :second)
      later = late_observed_session(later_pin)

      counts = Retention.prune_all(session_due)

      assert counts.expired_ai_runtime_sessions == 1
      assert counts.expired_runtime_cost_ledgers == 1

      # The session sweep ran first and cascaded this account's trail away, so
      # the observation count reports the surviving run's row only and never
      # double-counts what the cascade removed.
      assert counts.expired_agent_runtime_observations == 1

      assert Repo.get(AIRuntimeSession, context.session.session_id) == nil
      assert Repo.get(AIRuntimeSession, later.session.session_id)
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 0
    end
  end

  defp owner(context) do
    RuntimeProjections.owner_projection(
      context.account,
      context.session.session_id,
      now: @now
    )
  end

  defp participant(project, actor, context) do
    RuntimeProjections.participant_projection(
      project.id,
      actor,
      context.session.session_id
    )
  end

  # One more pinned run of the same account, with its own observation, so a
  # deletion scoped to one consumer can be shown to leave the others intact.
  defp observed_session(context, consumer, consumer_ref) do
    session =
      ai_runtime_session_fixture(context, %{
        now: @now,
        consumer: consumer,
        consumer_ref: consumer_ref
      })

    scoped = Map.put(context, :session, session)
    Map.put(scoped, :observation, runtime_observation_fixture(scoped, %{now: @ingested_at}))
  end

  defp observed_account do
    context = runtime_observation_context_fixture(%{now: @now, authentication_mode: "api_key"})

    Map.put(context, :observation, runtime_observation_fixture(context, %{now: @ingested_at}))
  end

  defp late_observed_session(pinned_at) do
    context = runtime_observation_context_fixture(%{now: pinned_at})
    observed_at = DateTime.add(pinned_at, 30, :second)

    observation =
      runtime_observation_fixture(context, %{
        observed_at: observed_at,
        now: DateTime.add(observed_at, 60, :second)
      })

    Map.put(context, :observation, observation)
  end

  defp observation_count(context) do
    Repo.aggregate(
      from(observation in AgentRuntimeObservation,
        where: observation.session_id == ^context.session.session_id
      ),
      :count
    )
  end

  defp project_scope do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: "Trail Reader"
    })

    Map.merge(result, %{
      identity: identity,
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end

  # The sweep's lock is session-scoped and re-entrant within one session, so the
  # shared sandbox connection cannot stand in for a competing instance.
  defp start_lock_holder do
    {:ok, holder} = Postgrex.start_link(postgrex_options())
    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [
               Retention.observation_advisory_lock_key()
             ])

    holder
  end

  defp release_lock_holder(holder) do
    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [
               Retention.observation_advisory_lock_key()
             ])
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
