defmodule SddOrchestrator.Delivery.ReviewTest do
  @moduledoc """
  Proof for authorized review approval and rejection (Task 34).

  One promise is pinned above every other: the final product decision belongs to
  two people and nobody else. The participant responsibility currently resolves
  to may decide, the project owner may decide, and every other current
  participant, every departed one, and every agent is refused — with the feature,
  the run, the attempt, and every record left exactly as they were, compared
  whole rather than field by chosen field [AC-24].

  The second promise is that an approval is the one move that finishes a feature:
  `Ready for review` to `Done`, recorded as an immutable verdict naming exactly
  the branch and commit the gate proved [AC-25].

  The third is the boundary with Task 35. This file proves the verdict a
  rejection records — its feedback, its immutability, and its idempotency — and
  `review_continuation_test.exs` proves what that same commit does to the run.
  The two land together deliberately, so a rejection can never leave a feature
  stranded in `Ready for review` with a verdict nobody acted on.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's records in the
  hosted database and two implementations are only safe once they answer the
  same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    Feature,
    Previews,
    Review,
    ReviewDecision,
    ReviewHandoff,
    RunTransitions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.PreviewAdapterDouble
  alias SddOrchestrator.Repo

  @contract ["mix test", "mix credo"]
  @commit "a1b2c3d4e5f6a7b8c9d0"
  @path "web"
  @feedback "The empty state still shows a spinner"

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()

    # Responsibility resolves to the assignee, so the responsible participant and
    # the owner are deliberately two different people: an authority that covered
    # both by accident would prove neither.
    feature =
      DeliveryFixtures.feature_fixture(hosted.project, hosted.account, %{
        assigned_account_id: hosted.identity.account.id
      })

    bystander = current_participant(hosted.project)

    path = Path.join(System.tmp_dir!(), "review-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    # A device-authoritative project keeps its own approved profile, which is
    # what a continued attempt's manifest is built from under this authority.
    authority =
      case context[:authority] do
        :device ->
          workspace = %DeviceWorkspace{id: device_workspace.id}
          DeliveryFixtures.approve_device_profile!(workspace, hosted.project)
          workspace

        _hosted ->
          hosted.workspace
      end

    developing = seed_feature(authority, hosted.project, feature)
    %{run: run, attempt: attempt} = seed_run(authority, hosted.project, developing)

    %{
      authority: authority,
      hosted: hosted,
      project: hosted.project,
      owner: hosted.account,
      owner_actor: hosted.owner_actor,
      responsible: hosted.identity,
      responsible_actor: hosted.participant_actor,
      bystander: bystander,
      bystander_actor: %{
        account_id: bystander.account.id,
        hosted_identity_id: bystander.hosted_identity.id
      },
      # An agent holds no member identity at all, which is what makes the
      # participation guard its first and final refusal.
      agent_actor: %{account_id: nil, hosted_identity_id: nil},
      feature: developing,
      run: run,
      attempt: attempt
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "who may decide (#{authority})" do
      @describetag authority: authority

      test "the current responsible participant may approve [AC-25]", context do
        context = ready(context)

        assert {:ok, results} = approve(context, context.responsible_actor)
        assert results.applied?
        assert results.decision.reviewer_account_id == context.responsible.account.id
      end

      test "the current responsible participant may reject", context do
        context = ready(context)

        assert {:ok, results} = reject(context, context.responsible_actor, @feedback)
        assert results.applied?
        assert results.decision.reviewer_account_id == context.responsible.account.id
      end

      test "the project owner may approve although they are not responsible [AC-25]",
           context do
        context = ready(context)

        # Responsibility genuinely resolves elsewhere; the owner's authority is
        # what keeps a feature finishable when it does.
        assert responsible_account(context) == context.responsible.account.id

        assert {:ok, results} = approve(context, context.owner_actor)
        assert results.applied?
        assert results.decision.reviewer_account_id == context.owner.id
        assert results.feature.lifecycle_column == "done"
      end

      test "the project owner may reject although they are not responsible", context do
        context = ready(context)

        assert {:ok, results} = reject(context, context.owner_actor, @feedback)
        assert results.applied?
        assert results.decision.reviewer_account_id == context.owner.id
      end

      test "another current participant may neither approve nor reject [AC-24]", context do
        context = ready(context)
        before = world(context)

        assert {:error, :unauthorized} = approve(context, context.bystander_actor)
        assert {:error, :unauthorized} = reject(context, context.bystander_actor, @feedback)

        # Not merely refused: nothing about the feature, the run, the attempt,
        # the verdicts, or the history moved at all.
        assert world(context) == before
      end

      test "an agent may neither approve nor reject [AC-24]", context do
        context = ready(context)
        before = world(context)

        assert {:error, :unauthorized} = approve(context, context.agent_actor)
        assert {:error, :unauthorized} = reject(context, context.agent_actor, @feedback)

        assert world(context) == before
      end

      test "a participant who has left takes no review authority with them [AC-24]", context do
        context = ready(context)

        # They were the responsible participant when the work reached review.
        assert responsible_account(context) == context.responsible.account.id

        {:ok, _removed} =
          Revocations.remove(
            context.project,
            context.owner.id,
            context.responsible.hosted_identity.id
          )

        before = world(context)

        assert {:error, :unauthorized} = approve(context, context.responsible_actor)
        assert {:error, :unauthorized} = reject(context, context.responsible_actor, @feedback)

        assert world(context) == before
      end

      test "a feature that is not in review cannot be decided", context do
        # Still in development: nothing has been handed to a reviewer yet.
        assert context.feature.lifecycle_column == "in_development"
        before = world(context)

        assert {:error, :not_in_review} = approve(context, context.owner_actor)
        assert {:error, :not_in_review} = reject(context, context.owner_actor, @feedback)

        assert world(context) == before
      end

      test "a reviewable feature with no verified completion behind it is refused", context do
        # The board says `Ready for review` but no gate ever proved anything, so
        # there is nothing to decide about.
        moved = force_into_review(context)
        before = world(moved)

        assert {:error, :not_verified} = approve(moved, moved.owner_actor)
        assert world(moved) == before
      end
    end

    describe "recording an approval (#{authority})" do
      @describetag authority: authority

      test "the feature moves to `Done` [AC-25]", context do
        context = ready(context)

        assert {:ok, results} = approve(context, context.responsible_actor)

        assert results.feature.lifecycle_column == "done"
        assert results.feature.status == "none"
        assert reload_feature(context).lifecycle_column == "done"
      end

      test "the verdict names the branch and commit the gate proved", context do
        context = ready(context)

        {:ok, %{decision: decision}} = approve(context, context.responsible_actor)

        assert decision.decision == "approved"
        assert decision.run_id == context.run.id
        assert decision.attempt_id == context.attempt.id
        assert decision.branch == context.run.branch
        assert decision.commit_sha == @commit
        refute decision.feedback

        assert Review.decision(context.authority, context.project.id, context.feature).id ==
                 decision.id
      end

      test "the verdict names the preview the reviewer could have opened", context do
        context = ready(context)

        on_exit(
          PreviewAdapterDouble.install(
            script: :ready,
            projects: %{context.project.id => [@path]}
          )
        )

        {:ok, %{deployment: deployment}} =
          Previews.start(context.authority, context.project.id, context.run, path: @path)

        {:ok, %{decision: decision, activity: activity}} =
          approve(context, context.responsible_actor)

        assert decision.preview_deployment_id == deployment.id
        assert activity.payload["preview_deployment_id"] == deployment.id
      end

      test "a feature with no preview at all still decides", context do
        context = ready(context)

        assert Previews.list(context.authority, context.project.id) == []

        assert {:ok, %{decision: decision}} = approve(context, context.responsible_actor)
        refute decision.preview_deployment_id
        assert reload_feature(context).lifecycle_column == "done"
      end

      test "the approval is recorded as one ordered participant activity entry", context do
        context = ready(context)

        {:ok, %{activity: activity}} = approve(context, context.responsible_actor)

        assert activity.type == Review.approved_activity_type()
        assert activity.actor_kind == "participant"
        assert activity.actor_account_id == context.responsible.account.id
        assert activity.run_id == context.run.id
        assert activity.attempt_id == context.attempt.id
        assert activity.payload["decision"] == "approved"
        assert activity.payload["column"] == "done"
        assert activity.payload["commit_sha"] == @commit
        refute activity.payload["feedback"]

        assert length(decisions_of(context, "approved")) == 1
      end

      test "a repeated approval decides once and writes nothing twice", context do
        context = ready(context)

        {:ok, first} = approve(context, context.responsible_actor)
        assert first.applied?

        assert {:ok, second} = approve(context, context.responsible_actor)
        refute second.applied?
        assert second.decision.id == first.decision.id
        assert second.activity.id == first.activity.id
        assert second.feature.lifecycle_column == "done"

        assert length(recorded_decisions(context)) == 1
        assert length(decisions_of(context, "approved")) == 1
      end
    end

    describe "recording a rejection (#{authority})" do
      @describetag authority: authority

      test "rejection without feedback is refused and writes nothing", context do
        context = ready(context)
        before = world(context)

        assert {:error, :feedback_required} = reject(context, context.responsible_actor, "")
        assert {:error, :feedback_required} = reject(context, context.responsible_actor, nil)

        assert world(context) == before
      end

      test "whitespace-only feedback is not feedback", context do
        context = ready(context)
        before = world(context)

        assert {:error, :feedback_required} =
                 reject(context, context.responsible_actor, "  \n\t ")

        assert world(context) == before
      end

      test "feedback past the byte limit is refused before anything is written", context do
        context = ready(context)
        before = world(context)

        oversized = String.duplicate("a", ReviewDecision.max_feedback_bytes() + 1)

        assert {:error, :feedback_too_long} =
                 reject(context, context.responsible_actor, oversized)

        assert world(context) == before
      end

      test "the verdict and its activity record what has to change", context do
        context = ready(context)

        {:ok, %{decision: decision, activity: activity}} =
          reject(context, context.responsible_actor, "  #{@feedback}  ")

        assert decision.decision == "rejected"
        assert decision.feedback == @feedback
        assert decision.branch == context.run.branch
        assert decision.commit_sha == @commit
        assert decision.reviewer_account_id == context.responsible.account.id

        assert activity.type == Review.rejected_activity_type()
        assert activity.actor_kind == "participant"
        assert activity.payload["decision"] == "rejected"
        assert activity.payload["feedback"] == @feedback
      end

      test "the verdict and its continuation land in one commit [AC-26]", context do
        context = ready(context)

        assert {:ok, results} = reject(context, context.responsible_actor, @feedback)
        assert results.applied?

        # Deliberate and load-bearing. The verdict is not recorded a moment
        # before the feature moves: both are one commit, so a crash can never
        # leave a rejected feature parked in `Ready for review` with a verdict
        # nobody acted on.
        assert results.feature.lifecycle_column == "in_development"
        assert reload_feature(context).lifecycle_column == "in_development"
        assert results.activity.payload["column"] == "in_development"
        assert results.attempt.continuation_reason == "review_feedback"
        assert results.command.operation == "resume"
      end

      test "a repeated rejection decides once and writes nothing twice", context do
        context = ready(context)

        {:ok, first} = reject(context, context.responsible_actor, @feedback)
        assert first.applied?

        assert {:ok, second} = reject(context, context.responsible_actor, @feedback)
        refute second.applied?
        assert second.decision.id == first.decision.id
        assert second.activity.id == first.activity.id

        assert length(recorded_decisions(context)) == 1
      end

      test "an attempt already rejected cannot then be approved", context do
        context = ready(context)

        {:ok, rejected} = reject(context, context.responsible_actor, @feedback)

        # The attempt is decided. Approving it answers with the verdict that was
        # actually made rather than recording a second one, so the store's
        # one-verdict-per-attempt rule is never even reached.
        assert {:ok, %{applied?: false, decision: held}} = approve(context, context.owner_actor)

        assert held.id == rejected.decision.id
        assert held.decision == "rejected"
        assert reload_feature(context).lifecycle_column == "in_development"
        assert length(recorded_decisions(context)) == 1
      end
    end

    describe "what a recorded verdict discloses (#{authority})" do
      @describetag authority: authority

      test "no display name and no address reaches the record or its history", context do
        context = ready(context)

        {:ok, %{decision: decision, activity: activity}} =
          reject(context, context.responsible_actor, @feedback)

        label = Participation.member_profile(context.project.id, decision.reviewer_account_id)
        assert label.display_name

        value = ReviewDecision.to_value(decision)

        refute scan(value) =~ label.display_name
        refute scan(activity.payload) =~ label.display_name
        refute scan(value) =~ "@"
        refute scan(activity.payload) =~ "@"
      end
    end

    describe "answering whether a decision control may be shown (#{authority})" do
      @describetag authority: authority

      test "the responsible participant and the owner may decide", context do
        context = ready(context)

        assert {:ok, true} = reviewable(context, context.responsible_actor)
        assert {:ok, true} = reviewable(context, context.owner_actor)
      end

      test "another current participant is answered `false`, not denied [AC-24]", context do
        context = ready(context)

        assert {:ok, false} = reviewable(context, context.bystander_actor)
      end

      test "an agent and an outsider are denied outright [AC-24]", context do
        context = ready(context)

        assert {:error, :unauthorized} = reviewable(context, context.agent_actor)

        assert {:error, :unauthorized} =
                 reviewable(context, %{account_id: Ecto.UUID.generate(), hosted_identity_id: nil})
      end

      test "a feature that is not in review offers no decision", context do
        assert {:ok, false} = reviewable(context, context.responsible_actor)
      end
    end
  end

  describe "device authority creates no hosted copy" do
    @describetag authority: :device

    test "a device approval leaves the hosted feature and decision tables untouched",
         context do
      context = ready(context)

      {:ok, %{decision: decision, feature: feature}} = approve(context, context.responsible_actor)

      assert feature.lifecycle_column == "done"

      # The records genuinely exist — on the device, not in PostgreSQL.
      assert Repo.get!(Feature, context.feature.id).lifecycle_column == "draft"
      refute Repo.get(ReviewDecision, decision.id)
      assert Repo.aggregate(ReviewDecision, :count) == 0
    end
  end

  defp approve(context, actor), do: Review.approve(context.authority, actor, subject(context))

  defp reject(context, actor, feedback),
    do: Review.reject(context.authority, actor, subject(context), feedback)

  defp reviewable(context, actor),
    do: Review.reviewable(context.authority, actor, subject(context))

  defp subject(context), do: %{project: context.project, feature: context.feature}

  # Verified proof, then the handoff that actually puts the feature in front of a
  # reviewer. Reaching `Ready for review` any other way would prove the fixture
  # rather than the behaviour.
  defp ready(context) do
    DeliveryFixtures.verified_completion_fixture(
      context.authority,
      context.project,
      context.run,
      context.attempt
    )

    {:ok, %{feature: feature}} =
      ReviewHandoff.deliver(context.authority, context.project.id, context.run)

    %{context | feature: feature}
  end

  # A feature parked in review with no gate behind it: the corrupted state a
  # decision must refuse rather than record something about.
  defp force_into_review(context) do
    moved =
      move(
        context.authority,
        context.project,
        context.feature,
        "ready_for_review",
        "run_completed"
      )

    %{context | feature: moved}
  end

  # The state a refused decision must never be able to move. Compared whole,
  # because the point is that *nothing* changed rather than that one chosen
  # field did not.
  defp world(context) do
    {:ok, run} = DeliveryStore.fetch_run(context.authority, context.project.id, context.run.id)

    {:ok, attempt} =
      DeliveryStore.latest_attempt(context.authority, context.project.id, context.run.id)

    feature = reload_feature(context)

    %{
      run: {run.state, run.state_version},
      attempt: {attempt.state, attempt.attempt_number, attempt.state_version},
      feature: {feature.lifecycle_column, feature.status, feature.state_version},
      decisions: Enum.map(recorded_decisions(context), &{&1.id, &1.decision}),
      activity: Enum.map(activity(context), &{&1.id, &1.type, &1.sequence})
    }
  end

  defp recorded_decisions(context),
    do: DeliveryStore.list_review_decisions(context.authority, context.project.id)

  defp decisions_of(context, type) do
    context
    |> activity()
    |> Enum.filter(&(&1.type == "review_#{type}"))
  end

  defp activity(context),
    do: DeliveryStore.list_activity(context.authority, context.project.id, context.feature.id)

  defp responsible_account(context) do
    context.project.id
    |> ReviewHandoff.responsible(context.feature)
    |> Map.get(:account_id)
  end

  defp scan(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  # The device authority keeps its own feature copy, so a reload has to ask the
  # store the decision actually wrote to.
  defp reload_feature(context) do
    case DeliveryStore.fetch_feature(context.authority, context.project.id, context.feature.id) do
      {:ok, feature} -> feature
      :error -> Repo.get!(Feature, context.feature.id)
    end
  end

  defp current_participant(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Bystander")
    })

    identity
  end

  # A device-authoritative project's feature lives in the device store, so the
  # world each authority operates on has to be its own.
  defp seed_feature(authority, project, feature) do
    authority
    |> put_device_feature(project, feature)
    |> then(&develop(authority, project, &1))
  end

  defp put_device_feature(%DeviceWorkspace{}, project, feature) do
    {:ok, _written} =
      Devices.commit_delivery(project.id, [
        {:put, :feature, feature.id, Feature.to_value(feature), nil}
      ])

    feature
  end

  defp put_device_feature(_hosted, _project, feature), do: feature

  # A feature reaches `In development` only through `Ready for development`;
  # the transition table is what makes the board's gates real.
  defp develop(authority, project, feature) do
    ready = move(authority, project, feature, "ready_for_development", "readiness_evaluated")
    move(authority, project, ready, "in_development", "run_started")
  end

  defp move(authority, project, feature, column, type) do
    {:ok, %{results: %{feature: moved}}} =
      RunTransitions.apply(authority, %{
        operation_key: "#{column}:#{feature.id}",
        project_id: project.id,
        feature: feature,
        feature_column: column,
        activity: %{
          project_id: project.id,
          feature_id: feature.id,
          actor_kind: "system",
          type: type,
          payload: %{}
        }
      })

    moved
  end

  defp seed_run(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/feature-#{unique}"
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            required_checks: DeliveryFixtures.required_check_contract(@contract),
            fence_token: 1
          }}}
      ])

    %{run: run, attempt: attempt}
  end
end
