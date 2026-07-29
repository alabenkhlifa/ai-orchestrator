defmodule SddOrchestrator.Delivery.QuestionRoutingTest do
  @moduledoc """
  Proof for blocking-question responsibility routing (Task 23).

  Three promises are pinned here. A question reaches the person who can answer
  it — the assignee when there is one, the creator when there is not. It never
  reaches someone whose access ended: a departed assignee and a departed
  creator both route to the immutable owner, proved with a real removal rather
  than a flag. And nobody learns an address or the identity of a responder they
  are not: every identity on this path is a project display name or an account
  reference, and every refusal is the same undifferentiated one.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    Assignment,
    Blocking,
    EventIngestion,
    Feature,
    QuestionRouting,
    RunAttempt,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
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

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    context = DeliveryFixtures.delivery_project_fixture()

    # A third member is what separates "fell back to the creator" from "fell
    # back to the owner": with only two, both answers look identical.
    author = extra_participant(context.project, "Author")

    feature = DeliveryFixtures.feature_fixture(context.project, author.account)

    %{
      context: context,
      project: context.project,
      feature: feature,
      author: author,
      author_account: author.account,
      author_actor: %{
        account_id: author.account.id,
        hosted_identity_id: author.hosted_identity.id
      },
      owner_account: context.account,
      participant_account: context.identity.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "the responder set" do
    test "tags the assigned participant even when the creator is someone else [AC-05]", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account,
      author_account: author_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert [responder] = QuestionRouting.responders(project.id, assigned)
      assert responder.account_id == participant_account.id
      refute responder.account_id == author_account.id
      assert assigned.creator_account_id == author_account.id
    end

    test "tags the creator when `Assigned` is empty [AC-06]", %{
      project: project,
      feature: feature,
      author_account: author_account
    } do
      refute feature.assigned_account_id

      assert [responder] = QuestionRouting.responders(project.id, feature)
      assert responder.account_id == author_account.id
    end

    test "returns to the creator when the assignment is cleared [AC-06]", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account,
      author_account: author_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)
      {:ok, cleared} = Assignment.unassign(project.id, owner, assigned)

      assert [responder] = QuestionRouting.responders(project.id, cleared)
      assert responder.account_id == author_account.id
    end

    test "is empty for a feature belonging to another project", %{feature: feature} do
      other = DeliveryFixtures.delivery_project_fixture()

      assert QuestionRouting.responders(other.project.id, feature) == []
    end
  end

  describe "stale responsibility" do
    test "routes a stale assignee to the creator, never to the former participant", %{
      project: project,
      feature: feature,
      context: context,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account,
      author_account: author_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert [responder] = QuestionRouting.responders(project.id, assigned)
      assert responder.account_id == author_account.id
      refute responder.account_id == participant_account.id
    end

    test "routes a stale creator to the owner when nobody is assigned", %{
      project: project,
      feature: feature,
      author: author,
      owner_account: owner_account,
      author_account: author_account
    } do
      {:ok, _removed} = Revocations.remove(project, owner_account.id, author.hosted_identity.id)

      assert [responder] = QuestionRouting.responders(project.id, feature)
      assert responder.account_id == owner_account.id
      assert responder.role == :owner
      refute responder.account_id == author_account.id
    end

    test "routes to the owner when the assignee and the creator have both left", %{
      project: project,
      feature: feature,
      context: context,
      author: author,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account,
      author_account: author_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      {:ok, _assignee_removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      {:ok, _creator_removed} =
        Revocations.remove(project, owner_account.id, author.hosted_identity.id)

      assert [responder] = QuestionRouting.responders(project.id, assigned)
      assert responder.account_id == owner_account.id
      assert responder.role == :owner
      refute responder.account_id in [participant_account.id, author_account.id]
    end
  end

  describe "who is tagged" do
    test "tags the assignee and nobody else [AC-05]", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant,
      author_actor: author_actor,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert QuestionRouting.tagged?(project.id, assigned, participant)
      refute QuestionRouting.tagged?(project.id, assigned, author_actor)
      refute QuestionRouting.tagged?(project.id, assigned, owner)
    end

    test "tags the creator when nobody is assigned [AC-06]", %{
      project: project,
      feature: feature,
      author_actor: author_actor,
      owner: owner
    } do
      assert QuestionRouting.tagged?(project.id, feature, author_actor)
      refute QuestionRouting.tagged?(project.id, feature, owner)
    end

    test "stops tagging a participant the moment they leave", %{
      project: project,
      feature: feature,
      context: context,
      owner: owner,
      owner_account: owner_account,
      participant: participant,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)
      assert QuestionRouting.tagged?(project.id, assigned, participant)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      refute QuestionRouting.tagged?(project.id, assigned, participant)
    end

    test "tags nobody outside the project", %{project: project, feature: feature} do
      refute QuestionRouting.tagged?(project.id, feature, %{account_id: Ecto.UUID.generate()})
      refute QuestionRouting.tagged?(project.id, feature, %{})
    end
  end

  describe "authorizing an answer" do
    test "admits the current responder", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert {:ok, member} = QuestionRouting.authorize_answer(project.id, participant, assigned)
      assert member.account_id == participant_account.id
    end

    test "admits the creator when nobody is assigned [AC-06]", %{
      project: project,
      feature: feature,
      author_actor: author_actor,
      author_account: author_account
    } do
      assert {:ok, member} = QuestionRouting.authorize_answer(project.id, author_actor, feature)
      assert member.account_id == author_account.id
    end

    test "refuses another current participant without disclosing the responder", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      # The owner is a fully authorized participant here and is still refused,
      # and the refusal carries nothing that would identify the assignee.
      assert QuestionRouting.authorize_answer(project.id, owner, assigned) ==
               {:error, :unauthorized}
    end

    test "refuses an outsider, an anonymous caller, and a departed responder", %{
      project: project,
      feature: feature,
      context: context,
      owner: owner,
      owner_account: owner_account,
      participant: participant,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert QuestionRouting.authorize_answer(
               project.id,
               %{account_id: Ecto.UUID.generate()},
               assigned
             ) == {:error, :unauthorized}

      assert QuestionRouting.authorize_answer(project.id, %{}, assigned) ==
               {:error, :unauthorized}

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert QuestionRouting.authorize_answer(project.id, participant, assigned) ==
               {:error, :unauthorized}
    end

    test "admits the owner once responsibility has fallen back to them", %{
      project: project,
      feature: feature,
      author: author,
      owner: owner,
      owner_account: owner_account
    } do
      assert QuestionRouting.authorize_answer(project.id, owner, feature) ==
               {:error, :unauthorized}

      {:ok, _removed} = Revocations.remove(project, owner_account.id, author.hosted_identity.id)

      assert {:ok, member} = QuestionRouting.authorize_answer(project.id, owner, feature)
      assert member.account_id == owner_account.id
    end

    test "refuses a feature that belongs to another project", %{
      feature: feature,
      author_actor: author_actor
    } do
      other = DeliveryFixtures.delivery_project_fixture()

      assert QuestionRouting.authorize_answer(other.project.id, author_actor, feature) ==
               {:error, :unauthorized}

      assert QuestionRouting.authorize_answer(other.project.id, other.owner_actor, feature) ==
               {:error, :unauthorized}
    end
  end

  describe "presentation [AC-31]" do
    test "labels the responder by project display name", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      assert QuestionRouting.responder_label(project.id, feature) =~ "Author"

      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert QuestionRouting.responder_label(project.id, assigned) =~ "Member"
    end

    test "exposes no participant email in the responder set or its label", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      for subject <- [feature, assigned] do
        assert [responder] = QuestionRouting.responders(project.id, subject)
        refute Map.has_key?(responder, :email)
        refute responder.display_name =~ "@"
        refute responder |> Map.values() |> Enum.any?(&(is_binary(&1) and &1 =~ "@"))
        refute QuestionRouting.responder_label(project.id, subject) =~ "@"
      end
    end

    test "has no label at all when responsibility cannot resolve", %{feature: feature} do
      other = DeliveryFixtures.delivery_project_fixture()

      refute QuestionRouting.responder_label(other.project.id, feature)
    end
  end

  describe "the recorded question tag" do
    setup %{context: context, author_account: author_account} do
      feature =
        context.project |> DeliveryFixtures.feature_fixture(author_account) |> in_development()

      run = DeliveryFixtures.run_fixture(context.project, feature)
      pending = DeliveryFixtures.attempt_fixture(run, %{fence_token: 3})

      {:ok, attempt} =
        pending
        |> RunAttempt.transition_changeset("dispatched", pending.state_version)
        |> Repo.update()

      {:ok, _progress} =
        EventIngestion.ingest(context.workspace, context.project.id, progress(run, attempt))

      %{authority: context.workspace, blocked_feature: feature, run: run, attempt: attempt}
    end

    test "names the assigned responder by account reference [AC-05]", %{
      authority: authority,
      project: project,
      blocked_feature: feature,
      run: run,
      attempt: attempt,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, _assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      {:ok, results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert results.activity.type == "question_asked"
      assert results.activity.payload["responder_account_id"] == participant_account.id
    end

    test "names the creator when nobody is assigned [AC-06]", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt,
      author_account: author_account
    } do
      {:ok, results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert results.activity.payload["responder_account_id"] == author_account.id
    end

    test "names the owner when the creator has already left", %{
      authority: authority,
      project: project,
      author: author,
      owner_account: owner_account,
      run: run,
      attempt: attempt
    } do
      {:ok, _removed} = Revocations.remove(project, owner_account.id, author.hosted_identity.id)

      {:ok, results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert results.activity.payload["responder_account_id"] == owner_account.id
    end

    test "carries an account reference and no participant email", %{
      authority: authority,
      project: project,
      blocked_feature: feature,
      run: run,
      attempt: attempt,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, _assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)
      {:ok, _results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      encoded =
        ActivityEntry
        |> Repo.all()
        |> Enum.map(&ActivityEntry.to_value/1)
        |> Jason.encode!()

      assert encoded =~ participant_account.id
      refute encoded =~ "@example.com"
      refute encoded =~ "@"
    end
  end

  defp extra_participant(project, prefix) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name(prefix)
    })

    identity
  end

  defp in_development(feature) do
    {:ok, ready} =
      feature
      |> Feature.transition_changeset("ready_for_development", feature.state_version)
      |> Repo.update()

    {:ok, developing} =
      ready
      |> Feature.transition_changeset("in_development", ready.state_version)
      |> Repo.update()

    developing
  end

  defp progress(run, attempt) do
    run
    |> envelope(attempt, sequence: 1)
    |> Map.put("event_type", "progress")
    |> Map.put("payload", %{"summary" => "Working"})
  end

  defp blocked(run, attempt, opts) do
    payload = %{
      "question" => "Which retention window applies?",
      "checkpoint" => %{"stage" => "requirements"},
      "workspace_path" => "/var/sdd/workspaces/#{run.id}"
    }

    run |> envelope(attempt, opts) |> Map.put("payload", payload)
  end

  defp envelope(run, attempt, opts) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "blocked",
      "source" => "agent",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{}
    }
  end
end
