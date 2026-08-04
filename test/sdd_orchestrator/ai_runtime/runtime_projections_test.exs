defmodule SddOrchestrator.AIRuntime.RuntimeProjectionsTest do
  @moduledoc "Task 5 proof for access-safe owner-exact and participant-safe projections."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.AIRuntime.QuotaSnapshot
  alias SddOrchestrator.AIRuntime.RuntimeProjections
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationFixtures

  @now ~U[2026-08-03 12:00:00Z]
  @expired ~U[2026-08-03 13:00:00Z]
  @ingested_at ~U[2026-08-03 12:05:00Z]

  @owner_keys ~w(
    session_id consumer consumer_ref provider authentication_mode model effort
    pinned_at availability usage quota spend observations
  )a

  @participant_keys ~w(session_id model effort usage availability observations)a

  @participant_observation_keys ~w(sequence observed_at elapsed tokens status unknown_fields)a

  @spend_keys ~w(currency ceiling reserved observed remaining paused pause_reason)a

  # Nothing named here may appear as a key anywhere inside a participant-safe
  # projection, at any nesting depth.
  @forbidden_names ~w(
    account_id connection_id consumer_ref consumer provider authentication_mode
    provenance opt_ins pinned_at estimated_cost quota event_key observation_id
    session buckets reset_credits token_activity snapshot_id expires_at
    outstanding bounded_request remaining reserved observed
  )

  @forbidden_fragments ~w(ceiling credit spend price catalog)

  describe "owner-exact projection" do
    test "projects one working-agent run with its account-wide quota and usage" do
      context = run_context()
      observe(context)

      assert {:ok, projection} = owner(context)

      assert Enum.sort(Map.keys(projection)) == Enum.sort(@owner_keys)
      assert projection.session_id == context.session.session_id
      assert projection.consumer == :working_agent
      assert projection.consumer_ref == context.session.consumer_ref
      assert projection.provider == "openai_codex"
      assert projection.authentication_mode == "chatgpt"
      assert projection.model == "codex-test-model"
      assert projection.effort == "medium"
      assert projection.pinned_at == @now

      assert projection.availability == %{
               state: :available,
               pause_reason: nil,
               source: :provider_fact
             }

      assert projection.usage.elapsed == %{seconds: 30, source: :worker_observed}

      assert projection.usage.tokens == %{
               input: 1_200,
               output: 300,
               total: 1_500,
               source: :worker_observed
             }

      assert projection.usage.estimated_cost.currency == "USD"
      assert projection.usage.estimated_cost.source == :local_estimate
      assert length(projection.observations) == 1
    end

    test "projects one support-assistant conversation through the same rules" do
      context = run_context(%{consumer: :support_assistant})
      observe(context)

      assert {:ok, projection} = owner(context)

      assert Enum.sort(Map.keys(projection)) == Enum.sort(@owner_keys)
      assert projection.consumer == :support_assistant
      assert projection.availability.state == :available
      assert projection.usage.tokens.total == 1_500
      assert length(projection.observations) == 1
    end

    test "carries account-wide quota buckets, credits, and paid continuation" do
      context = run_context()
      observe(context)

      assert {:ok, %{quota: quota}} = owner(context)

      refute quota == %{state: :unknown}
      assert [bucket] = quota.buckets
      assert bucket.id == "general"
      assert bucket.credits.has_credits
      assert bucket.credits.balance
      assert bucket.paid_continuation == "unknown"
      assert quota.reset_credits.available_count == 2
      assert quota.token_activity.lifetime_tokens == 12_000
    end

    test "carries the strict spending ceiling of an API-key run" do
      context = cost_context()
      observe(context)
      runtime_cost_ledger_fixture(context, %{now: @now})

      assert {:ok, %{spend: spend, quota: quota}} = owner(context)

      assert Enum.sort(Map.keys(spend)) == Enum.sort(@spend_keys)
      assert spend.currency == "USD"
      assert Decimal.equal?(spend.ceiling, Decimal.new("1.0000"))
      assert Decimal.equal?(spend.reserved, Decimal.new("0.0000"))
      assert Decimal.equal?(spend.observed, Decimal.new("0.0000"))
      assert Decimal.equal?(spend.remaining, Decimal.new("1.0000"))
      refute spend.paused
      assert spend.pause_reason == nil

      # The reservation mechanics that enforce the ceiling are not an owner
      # runtime view.
      for internal <- ~w(outstanding price bounded_request)a do
        refute Map.has_key?(spend, internal)
      end

      # An API-key connection reports no account-wide quota as a provider fact,
      # which is a current answer rather than missing evidence.
      assert quota.status == "unknown"
      assert quota.buckets == []
      refute Map.has_key?(quota, :state)
    end

    test "reports a ChatGPT session's spend as not applicable" do
      context = run_context()
      observe(context)

      assert {:ok, projection} = owner(context)
      assert projection.spend == %{state: :not_applicable}
    end

    test "reports an absent and an expired quota snapshot as unknown, never as zero" do
      context = run_context()
      observe(context)

      assert {:ok, expired} = owner(context, now: @expired)
      assert expired.quota == %{state: :unknown}

      Repo.delete_all(QuotaSnapshot)

      assert {:ok, absent} = owner(context)
      assert absent.quota == %{state: :unknown}
      refute Map.has_key?(absent.quota, :buckets)
      refute Map.has_key?(absent.quota, :status)

      # The stored run history survives an unknown account-wide fact.
      assert length(absent.observations) == 1
    end

    test "keeps stored history readable after the connection is detached" do
      context = run_context()
      observe(context)
      detach(context)

      assert {:ok, projection} = owner(context)

      assert projection.quota == %{state: :unknown}
      assert projection.model == "codex-test-model"
      assert [observation] = projection.observations
      assert observation.sequence == 1
      assert projection.usage.tokens.total == 1_500
    end

    test "refuses another account's session as not found" do
      context = run_context()
      observe(context)
      other = AccountsFixtures.account_fixture()

      assert {:error, :not_found} =
               RuntimeProjections.owner_projection(other, context.session.session_id)

      assert {:error, :not_found} =
               RuntimeProjections.owner_projection(context.account, Ecto.UUID.generate())
    end
  end

  describe "participant-safe projection" do
    test "projects the run for a current participant and for the project owner" do
      %{project: project, owner_actor: owner_actor, participant_actor: participant_actor} =
        project_scope()

      context = run_context()
      observe(context)
      session_id = context.session.session_id

      assert {:ok, participant} =
               RuntimeProjections.participant_projection(
                 project.id,
                 participant_actor,
                 session_id
               )

      assert {:ok, owner} =
               RuntimeProjections.participant_projection(project.id, owner_actor, session_id)

      assert participant == owner
      assert participant.session_id == session_id
      assert participant.model == "codex-test-model"
      assert participant.effort == "medium"
      assert participant.availability.state == :available
      assert participant.usage.elapsed == %{seconds: 30, source: :worker_observed}
      assert participant.usage.tokens.total == 1_500
    end

    test "exposes only the approved participant fields" do
      %{project: project, participant_actor: actor} = project_scope()
      context = run_context()
      observe(context)

      assert {:ok, projection} =
               RuntimeProjections.participant_projection(
                 project.id,
                 actor,
                 context.session.session_id
               )

      assert Enum.sort(Map.keys(projection)) == Enum.sort(@participant_keys)
      assert Enum.sort(Map.keys(projection.usage)) == Enum.sort(~w(elapsed tokens)a)

      assert Enum.sort(Map.keys(projection.availability)) ==
               Enum.sort(~w(state pause_reason source)a)

      assert [observation] = projection.observations

      assert Enum.sort(Map.keys(observation)) == Enum.sort(@participant_observation_keys)
      assert projection.availability.state in ~w(available constrained paused unknown)a
    end

    test "never carries a forbidden field at any depth" do
      %{project: project, participant_actor: actor} = project_scope()
      context = cost_context()
      observe(context)
      runtime_cost_ledger_fixture(context, %{now: @now})

      assert {:ok, projection} =
               RuntimeProjections.participant_projection(
                 project.id,
                 actor,
                 context.session.session_id
               )

      assert forbidden_keys(projection) == []

      # The walker is real: it finds a planted key at depth.
      planted = put_in(projection.observations, [%{elapsed: %{spending_ceiling: "1.00"}}])
      assert forbidden_keys(planted) == ["spending_ceiling"]

      refute inspect(projection) =~ context.account.id
      refute inspect(projection) =~ context.connection.id
    end

    test "the same run projects exact for the owner and safe for the participant" do
      %{project: project, participant_actor: actor} = project_scope()
      context = run_context()
      observe(context)
      session_id = context.session.session_id

      assert {:ok, exact} = owner(context)

      assert {:ok, safe} =
               RuntimeProjections.participant_projection(project.id, actor, session_id)

      assert exact.model == safe.model
      assert exact.effort == safe.effort
      assert exact.availability.state == safe.availability.state
      assert exact.usage.tokens == safe.usage.tokens
      assert exact.usage.elapsed == safe.usage.elapsed

      assert exact.quota.buckets != []
      assert Map.has_key?(exact.usage, :estimated_cost)
      refute Map.has_key?(safe, :quota)
      refute Map.has_key?(safe, :spend)
      refute Map.has_key?(safe.usage, :estimated_cost)
    end

    test "preserves the append order of the run's observations" do
      %{project: project, participant_actor: actor} = project_scope()
      context = run_context()

      for {sequence, seconds} <- [{1, 30}, {2, 60}, {3, 90}] do
        observe(context, %{
          event_key: "event-#{sequence}",
          sequence: sequence,
          observed_at: DateTime.add(@now, seconds, :second),
          elapsed: %{seconds: seconds, source: "worker_observed"}
        })
      end

      assert {:ok, exact} = owner(context)

      assert {:ok, safe} =
               RuntimeProjections.participant_projection(
                 project.id,
                 actor,
                 context.session.session_id
               )

      assert Enum.map(exact.observations, & &1.sequence) == [1, 2, 3]
      assert Enum.map(safe.observations, & &1.sequence) == [1, 2, 3]
      assert Enum.map(safe.observations, & &1.elapsed.seconds) == [30, 60, 90]
      assert safe.usage.elapsed.seconds == 90
    end
  end

  describe "uniform denial" do
    test "denies every unauthorized caller with the identical result" do
      %{project: project, participant_actor: actor, identity: identity} = project_scope()
      %{project: other_project, participant_actor: other_actor} = project_scope()

      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      context = run_context()
      observe(context)
      session_id = context.session.session_id

      support = run_context(%{consumer: :support_assistant})
      observe(support)

      assert {:ok, _permitted} =
               RuntimeProjections.participant_projection(project.id, actor, session_id)

      denials = [
        # A non-member outsider.
        RuntimeProjections.participant_projection(project.id, outsider_actor, session_id),
        # A current participant of a different project.
        RuntimeProjections.participant_projection(project.id, other_actor, session_id),
        RuntimeProjections.participant_projection(other_project.id, actor, session_id),
        # An unknown and a malformed project.
        RuntimeProjections.participant_projection(Ecto.UUID.generate(), actor, session_id),
        RuntimeProjections.participant_projection("not-an-id", actor, session_id),
        # An unknown and a malformed session.
        RuntimeProjections.participant_projection(project.id, actor, Ecto.UUID.generate()),
        RuntimeProjections.participant_projection(project.id, actor, "not-an-id"),
        # A personal support conversation is not a project run.
        RuntimeProjections.participant_projection(
          project.id,
          actor,
          support.session.session_id
        ),
        # An absent actor.
        RuntimeProjections.participant_projection(project.id, %{}, session_id),
        RuntimeProjections.participant_projection(project.id, nil, session_id)
      ]

      assert Enum.uniq(denials) == [{:error, :unavailable}]

      # Authorization is re-read on every call, so a departure denies at once.
      {:ok, _left} =
        Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      revoked = RuntimeProjections.participant_projection(project.id, actor, session_id)

      assert revoked == {:error, :unavailable}
      assert Enum.uniq([revoked | denials]) == [{:error, :unavailable}]
    end
  end

  describe "capability contract" do
    test "a downstream consumer reads both projections through the public API alone" do
      %{project: project, participant_actor: actor} = project_scope()
      context = cost_context()
      observe(context)
      runtime_cost_ledger_fixture(context, %{now: @now})

      # Everything a consumer holds: one account, one project scope, one
      # session reference.
      account = context.account
      session_id = context.session.session_id

      assert {:ok, exact} = RuntimeProjections.owner_projection(account, session_id, now: @now)

      assert {:ok, safe} =
               RuntimeProjections.participant_projection(project.id, actor, session_id)

      assert Enum.sort(Map.keys(exact)) == Enum.sort(RuntimeProjections.owner_keys())
      assert Enum.sort(Map.keys(safe)) == Enum.sort(RuntimeProjections.participant_keys())

      assert Enum.sort(Map.keys(hd(safe.observations))) ==
               Enum.sort(RuntimeProjections.participant_observation_keys())

      assert exact.session_id == safe.session_id
      assert Decimal.equal?(exact.spend.ceiling, Decimal.new("1.0000"))
      assert forbidden_keys(safe) == []

      # The boundary is read-only: reading changes no stored fact.
      before_session = Repo.get!(AIRuntimeSession, session_id)
      RuntimeProjections.owner_projection(account, session_id, now: @now)
      RuntimeProjections.participant_projection(project.id, actor, session_id)
      after_session = Repo.get!(AIRuntimeSession, session_id)

      assert after_session.updated_at == before_session.updated_at
    end
  end

  defp owner(context, opts \\ []) do
    RuntimeProjections.owner_projection(
      context.account,
      context.session.session_id,
      Keyword.put_new(opts, :now, @now)
    )
  end

  defp run_context(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put(:now, @now)
    |> runtime_observation_context_fixture()
  end

  defp cost_context(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put(:now, @now)
    |> runtime_cost_context_fixture()
  end

  defp observe(context, attrs \\ %{}) do
    runtime_observation_fixture(
      context,
      attrs |> Map.new() |> Map.put_new(:now, @ingested_at)
    )
  end

  defp detach(context) do
    {1, _returned} =
      Repo.update_all(
        from(session in AIRuntimeSession, where: session.id == ^context.session.session_id),
        set: [connection_id: nil]
      )

    :ok
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
      display_name: "Run Reader"
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

  defp forbidden_keys(value) do
    value
    |> collect_keys()
    |> Enum.filter(&forbidden?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_keys(value) when is_struct(value), do: []

  defp collect_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> [to_string(key) | collect_keys(item)] end)
  end

  defp collect_keys(value) when is_list(value), do: Enum.flat_map(value, &collect_keys/1)

  defp collect_keys(_value), do: []

  defp forbidden?(key) do
    key in @forbidden_names or Enum.any?(@forbidden_fragments, &String.contains?(key, &1))
  end
end
