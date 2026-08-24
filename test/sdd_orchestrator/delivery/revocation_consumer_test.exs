defmodule SddOrchestrator.Delivery.RevocationConsumerTest do
  @moduledoc """
  Proof for consuming a participation departure (Task 27).

  Two boundaries are pinned here at once. The first is what a departure does to
  delivery: the current assignment clears, pending question and review
  responsibility lands on the owner, the active run keeps running under the
  owner's authority, prior activity is not rewritten, and the former participant
  can no longer reach anything.

  The second is what this slice is not allowed to do. Participation is another
  specification's record. These tests compare the participation tables before
  and after a full consumer pass and require them to be identical apart from the
  handoff's own delivery markers, because a consumer that quietly edited a
  membership row would still make every behavioural assertion above pass.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Assignment,
    BlockingQuestion,
    Cancellation,
    DeliveryStore,
    Feature,
    Features,
    ParticipantGuard,
    QuestionRouting,
    RevocationConsumer
  }

  alias SddOrchestrator.DeliveryFixtures

  alias SddOrchestrator.Participation.{
    ParticipationRevocation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    ParticipationDeliveryDouble.succeed()

    context = DeliveryFixtures.delivery_project_fixture()
    departing = context.identity

    # The departing participant both created and holds this feature. Clearing the
    # assignment is therefore not enough on its own for responsibility to reach
    # the owner: the creator fallback has to fail too, which is exactly the case
    # AC-30 names.
    held =
      DeliveryFixtures.feature_fixture(context.project, departing.account, %{
        assigned_account_id: departing.account.id
      })

    %{
      authority: context.workspace,
      project: context.project,
      owner: context.owner_actor,
      owner_account: context.account,
      departing: departing,
      former_actor: context.participant_actor,
      held: held
    }
  end

  describe "applying one departure [AC-30]" do
    test "a removal clears the current assignment and records why", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(authority)
      assert applied.revocation_id == revocation.id
      assert applied.project_id == project.id
      assert applied.former_account_id == departing.account.id
      assert applied.cleared_feature_ids == [held.id]

      cleared = Repo.get!(Feature, held.id)

      assert is_nil(cleared.assigned_account_id)
      # The feature moved nowhere: a departure is not a lifecycle event.
      assert cleared.lifecycle_column == held.lifecycle_column
      assert cleared.creator_account_id == held.creator_account_id
    end

    test "the applied entry names an account reference and nothing else", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      entry = entry("revocation_applied")

      assert entry.feature_id == held.id
      assert entry.actor_kind == "system"
      assert is_nil(entry.actor_account_id)
      assert entry.payload["former_account_id"] == departing.account.id
      assert entry.payload["reason"] == "removed"
      assert entry.payload["contract_version"] == revocation.contract_version

      # A name or an address in project history would freeze an identity into a
      # record that is meant to be labelled from current participation.
      refute Enum.any?(Map.keys(entry.payload), &(&1 in ~w(display_name name email)))
    end

    test "a participant who leaves is applied exactly as a removal is", %{
      authority: authority,
      project: project
    } do
      {leaver, leaver_feature} = second_participant(project)

      {:ok, %{revocation: revocation}} =
        Revocations.leave(project, leaver.account.id, leaver.hosted_identity.id)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(authority)
      assert applied.revocation_id == revocation.id
      assert applied.cleared_feature_ids == [leaver_feature.id]

      assert is_nil(Repo.get!(Feature, leaver_feature.id).assigned_account_id)
      assert entry("revocation_applied").payload["reason"] == "left"
    end

    test "another participant's assignment and unassigned features are untouched", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing
    } do
      kept =
        DeliveryFixtures.feature_fixture(project, owner_account, %{
          assigned_account_id: owner_account.id
        })

      unassigned = DeliveryFixtures.feature_fixture(project, owner_account)

      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, [applied]} = RevocationConsumer.claim_and_apply(authority)

      refute kept.id in applied.cleared_feature_ids
      refute unassigned.id in applied.cleared_feature_ids

      assert Repo.get!(Feature, kept.id) == kept
      assert Repo.get!(Feature, unassigned.id) == unassigned
      assert entries("revocation_applied") == 1
    end
  end

  describe "responsibility after a departure [AC-30]" do
    test "a pending blocking question waits on the owner, and stays open", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      departing: departing,
      former_actor: former_actor,
      held: held
    } do
      developing = move(held, ~w(ready_for_development in_development))
      run = running_run(project, developing, departing.account.id)
      question = ask(authority, project, developing, run)

      assert [%{account_id: responder}] = QuestionRouting.responders(project.id, developing)
      assert responder == departing.account.id

      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      current = Repo.get!(Feature, developing.id)

      # Nothing here re-derives responsibility: the cleared field is enough for
      # the one resolution the whole slice already shares.
      assert {:ok, member} = Assignment.responsible(project.id, current)
      assert member.account_id == owner_account.id
      assert [%{account_id: account_id}] = QuestionRouting.responders(project.id, current)
      assert account_id == owner_account.id
      assert {:ok, _owner} = QuestionRouting.authorize_answer(project.id, owner, current)

      assert {:error, :unauthorized} =
               QuestionRouting.authorize_answer(project.id, former_actor, current)

      # The question itself is a delivery record the departure does not resolve.
      assert Repo.get!(BlockingQuestion, question.id) == question
    end

    test "a feature waiting for review becomes the owner's to review", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      departing: departing,
      former_actor: former_actor,
      held: held
    } do
      reviewable = move(held, ~w(ready_for_development in_development ready_for_review))

      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      current = Repo.get!(Feature, reviewable.id)

      assert current.lifecycle_column == "ready_for_review"
      assert {:ok, member} = Assignment.responsible(project.id, current)
      assert member.account_id == owner_account.id
      assert {:ok, _owner} = ParticipantGuard.authorize_action(project.id, owner, :review)

      assert {:error, :unauthorized} =
               ParticipantGuard.authorize_action(project.id, former_actor, :review)
    end

    test "the former participant reaches nothing on the project", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      departing: departing,
      former_actor: former_actor,
      held: held
    } do
      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      # Access ended at the participation guard, which re-reads current
      # participation on every call. This slice revokes nothing of its own.
      assert {:error, :unauthorized} = ParticipantGuard.authorize(project.id, former_actor)
      assert {:error, :unauthorized} = Features.fetch(project.id, former_actor, held.id)
      assert {:error, :unauthorized} = Features.board(project.id, former_actor)
      assert ParticipantGuard.current_members(project.id, former_actor) == []

      assert {:ok, _feature} = Features.fetch(project.id, owner, held.id)
    end
  end

  describe "what a departure leaves alone [AC-30]" do
    test "the active run stays live and under the owner's control", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      departing: departing,
      former_actor: former_actor,
      held: held
    } do
      developing = move(held, ~w(ready_for_development in_development))
      run = running_run(project, developing, departing.account.id)

      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      live = Repo.get!(AgentRun, run.id)

      assert live.state == "running"
      assert live.state_version == run.state_version
      assert live.branch == run.branch
      assert entries("run_canceled") == 0

      current = Repo.get!(Feature, developing.id)

      # The initiator left, so the owner is the only person who can still end it
      # — which is why ending it was never this consumer's decision to make.
      assert {:error, :unauthorized} =
               Cancellation.cancelable(authority, former_actor, %{
                 project: project,
                 feature: current
               })

      assert {:ok, offered} =
               Cancellation.cancelable(authority, owner, %{project: project, feature: current})

      assert offered.id == run.id

      assert {:ok, results} =
               Cancellation.cancel(authority, owner, %{project: project, feature: current})

      assert results.run.state == "canceled"
    end

    test "prior activity keeps its actor and is byte-identical afterwards", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      contribution =
        DeliveryFixtures.activity_fixture(project, held, %{
          actor_kind: "participant",
          actor_account_id: departing.account.id,
          type: "comment",
          payload: %{"body" => "Recorded before the departure."}
        })

      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      assert Repo.get!(ActivityEntry, contribution.id) == contribution
      assert Repo.get!(ActivityEntry, contribution.id).actor_account_id == departing.account.id

      # The last accepted project label is the producer's preserved historical
      # attribution, and this slice neither writes nor rewrites it.
      assert revocation.last_display_name ==
               Repo.get_by!(ProjectMemberProfile,
                 project_id: project.id,
                 account_id: departing.account.id
               ).display_name

      # Nothing renders the former participant as a current identity any more.
      assert Assignment.labels(project.id, Repo.get!(Feature, held.id)).assignee == nil
      assert Assignment.labels(project.id, Repo.get!(Feature, held.id)).creator == nil
    end
  end

  describe "the handoff itself [AC-30]" do
    test "one commit writes the feature once and appends one entry", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      {:ok, _revoked} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      # One version step is the proof: a second write of the same record inside
      # one commit would either bump twice or be rejected as stale.
      assert Repo.get!(Feature, held.id).state_version == held.state_version + 1
      assert entries("revocation_applied") == 1
    end

    test "a rejected step rolls the whole commit back", %{
      authority: authority,
      project: project,
      departing: departing,
      held: held
    } do
      # A payload the activity contract refuses, so the second step fails after
      # the first has already been applied inside the transaction.
      assert {:error, :activity, %Ecto.Changeset{}} =
               DeliveryStore.commit(authority, project.id, [
                 {:feature, {:clear_assignment, held}},
                 {:activity,
                  {:append_activity,
                   %{
                     project_id: project.id,
                     feature_id: held.id,
                     actor_kind: "system",
                     type: "revocation_applied",
                     payload: %{"token" => "never stored"}
                   }}}
               ])

      unchanged = Repo.get!(Feature, held.id)

      assert unchanged.assigned_account_id == departing.account.id
      assert unchanged.state_version == held.state_version
      assert entries("revocation_applied") == 0
    end

    test "the handoff is acknowledged, and only under this consumer's reference", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing
    } do
      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)

      assert RevocationConsumer.pending() |> Enum.map(& &1.id) == [revocation.id]

      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      acknowledged = Repo.get!(ParticipationRevocation, revocation.id)

      assert acknowledged.consumer_ref == RevocationConsumer.consumer_ref()
      refute is_nil(acknowledged.acknowledged_at)
      refute is_nil(acknowledged.claimed_at)

      # An acknowledged handoff is finished work, not work to repeat.
      assert RevocationConsumer.pending() == []
      assert RevocationConsumer.claim_and_apply(authority) == {:ok, []}
      assert entries("revocation_applied") == 1
    end

    test "a replay after a crash between the apply and the acknowledgement is a no-op", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(authority)

      applied_feature = Repo.get!(Feature, held.id)

      # The apply committed and the acknowledgement never landed. The producer
      # hands the same revocation back, exactly as its contract promises.
      ParticipationRevocation
      |> Repo.get!(revocation.id)
      |> Ecto.Changeset.change(acknowledged_at: nil, consumer_ref: nil)
      |> Repo.update!()

      assert {:ok, [replayed]} = RevocationConsumer.claim_and_apply(authority)

      # Nothing was left to clear, so nothing was written a second time.
      assert replayed.cleared_feature_ids == []
      assert Repo.get!(Feature, held.id) == applied_feature
      assert entries("revocation_applied") == 1
      refute is_nil(Repo.get!(ParticipationRevocation, revocation.id).acknowledged_at)
    end

    test "a departure with nothing assigned is still acknowledged", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing,
      held: held
    } do
      {:ok, _cleared} =
        held
        |> Feature.assignment_changeset(nil, held.state_version)
        |> Repo.update()

      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(authority)
      assert applied.cleared_feature_ids == []
      assert entries("revocation_applied") == 0
      refute is_nil(Repo.get!(ParticipationRevocation, revocation.id).acknowledged_at)
    end
  end

  describe "participation is not this slice's to write [AC-30]" do
    test "a full consumer pass mutates no participation record", %{
      authority: authority,
      project: project,
      owner_account: owner_account,
      departing: departing
    } do
      {leaver, _leaver_feature} = second_participant(project)
      {:ok, _removed} = remove(project, owner_account, departing)

      {:ok, _left} = Revocations.leave(project, leaver.account.id, leaver.hosted_identity.id)

      counts = participation_counts()
      participants = ordered(ProjectParticipant)
      profiles = ordered(ProjectMemberProfile)
      handoffs = Enum.map(ordered(ParticipationRevocation), &handoff_shape/1)

      identity_links =
        Enum.map(
          ordered(ParticipationRevocation),
          &{&1.former_account_id, &1.former_hosted_identity_id}
        )

      {:ok, applied} = RevocationConsumer.claim_and_apply(authority)

      assert length(applied) == 2
      assert participation_counts() == counts

      # Byte-identical rows, not merely the same number of them.
      assert ordered(ProjectParticipant) == participants
      assert ordered(ProjectMemberProfile) == profiles

      # The handoff's own delivery markers are the only participation fields an
      # approved consumer may move, and it moves them through the boundary.
      assert Enum.map(ordered(ParticipationRevocation), &handoff_shape/1) == handoffs

      # Acknowledging through the boundary also releases the two identity links,
      # which is `specs/25-participation-identity-lifecycle`'s minimization rule
      # rather than this consumer writing participation data of its own. They
      # were set before the pass, so this proves the release, not an empty field.
      assert Enum.all?(identity_links, fn {former, identity} ->
               former != nil and identity != nil
             end)

      for revocation <- ordered(ParticipationRevocation) do
        assert revocation.former_account_id == nil
        assert revocation.former_hosted_identity_id == nil
      end
    end

    test "a rejected apply acknowledges nothing", %{
      project: project,
      owner_account: owner_account,
      departing: departing
    } do
      {:ok, %{revocation: revocation}} = remove(project, owner_account, departing)

      # An authority this slice cannot read or commit through must not produce an
      # acknowledgement claiming the departure was applied — and must not even
      # claim the handoff, because claiming is a participation write.
      assert {:error, :unsupported_authority} =
               RevocationConsumer.claim_and_apply(:no_such_authority)

      untouched = Repo.get!(ParticipationRevocation, revocation.id)

      assert is_nil(untouched.acknowledged_at)
      assert is_nil(untouched.consumer_ref)
      assert is_nil(untouched.claimed_at)
      assert entries("revocation_applied") == 0
    end
  end

  defp remove(project, owner_account, departing),
    do: Revocations.remove(project, owner_account.id, departing.hosted_identity.id)

  # A second real participant, so leave and removal are both proved against a
  # membership the fixtures actually created.
  defp second_participant(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Leaver")
    })

    feature =
      DeliveryFixtures.feature_fixture(project, identity.account, %{
        assigned_account_id: identity.account.id
      })

    {identity, feature}
  end

  defp move(feature, columns) do
    Enum.reduce(columns, feature, fn column, current ->
      current
      |> Feature.transition_changeset(column, current.state_version)
      |> Repo.update!()
    end)
  end

  defp running_run(project, feature, initiator_account_id) do
    run =
      DeliveryFixtures.run_fixture(project, feature, %{
        initiator_account_id: initiator_account_id
      })

    DeliveryFixtures.activity_fixture(project, feature, %{
      type: "run_started",
      run_id: run.id,
      payload: %{"branch" => run.branch}
    })

    run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update!()
  end

  defp ask(authority, project, feature, run) do
    {:ok, %{question: question}} =
      DeliveryStore.commit(authority, project.id, [
        {:question,
         {:insert_blocking_question,
          %{
            project_id: project.id,
            feature_id: feature.id,
            run_id: run.id,
            question: "Which retention window applies to preview artifacts?",
            branch: run.branch,
            workspace_path: "/tmp/sdd/#{run.id}"
          }}}
      ])

    question
  end

  defp participation_counts do
    %{
      participants: Repo.aggregate(ProjectParticipant, :count),
      profiles: Repo.aggregate(ProjectMemberProfile, :count),
      revocations: Repo.aggregate(ParticipationRevocation, :count)
    }
  end

  defp ordered(schema), do: schema |> order_by([r], asc: r.id) |> Repo.all()

  # Everything about a handoff except the fields acknowledging it is allowed to
  # move: the delivery markers this consumer contract owns, and the two identity
  # links `specs/25-participation-identity-lifecycle` releases on acknowledgement
  # so an applied departure stops naming a person. Those are asserted separately
  # rather than simply excluded.
  defp handoff_shape(%ParticipationRevocation{} = revocation) do
    revocation
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :claimed_at,
      :acknowledged_at,
      :consumer_ref,
      :updated_at,
      :former_account_id,
      :former_hosted_identity_id
    ])
  end

  defp entries(type) do
    ActivityEntry |> where([e], e.type == ^type) |> Repo.aggregate(:count)
  end

  defp entry(type) do
    ActivityEntry |> where([e], e.type == ^type) |> Repo.one!()
  end
end
