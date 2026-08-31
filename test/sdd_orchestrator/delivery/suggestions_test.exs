defmodule SddOrchestrator.Delivery.SuggestionsTest do
  @moduledoc """
  Proof for suggestion dismissal and development readiness (Task 11).

  Dismissal is the one place a person can make guidance quieter, so the tests
  pin what it can and cannot reach: a blocker never, a superseded finding list
  never, and readiness only as an explicit outcome that still leaves starting
  development to a person.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    Feature,
    Readiness,
    ReadinessAssessment,
    Suggestions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  setup do
    restore = ReadinessGuidanceDouble.install()
    on_exit(restore)

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

    # Every guided part is written, so the only findings these tests see are the
    # ones the guidance double scripts. Dismissal and promotion are what is
    # being proven here, not the structural gate.
    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account, %{
        requirements: :filled
      })

    {:ok, _current} =
      SpecificationStore.create(
        context.workspace,
        context.project.id,
        SpecificationFixtures.specification_attrs(),
        actor_ref: "owner"
      )

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account
    }
  end

  describe "dismissing a suggestion [AC-12]" do
    setup ctx do
      %{assessment: assess(ctx, mixed_findings())}
    end

    test "a non-blocking suggestion stops preventing attention", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      assert {:ok, updated} =
               Suggestions.dismiss(
                 project.id,
                 owner,
                 feature.id,
                 "tighten-copy",
                 assessment.version
               )

      assert "tighten-copy" in updated.dismissed_ids

      assert Enum.map(ReadinessAssessment.suggestions(updated), & &1["id"]) == [
               "second-suggestion"
             ]
    end

    test "any current participant may dismiss", %{
      project: project,
      feature: feature,
      participant: participant,
      assessment: assessment
    } do
      assert {:ok, _updated} =
               Suggestions.dismiss(
                 project.id,
                 participant,
                 feature.id,
                 "tighten-copy",
                 assessment.version
               )
    end

    test "dismissing does not change what blocks the feature [AC-11]", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      {:ok, updated} =
        Suggestions.dismiss(project.id, owner, feature.id, "tighten-copy", assessment.version)

      assert Enum.map(ReadinessAssessment.blockers(updated), & &1["id"]) == ["missing-users"]
      refute ReadinessAssessment.start_available?(updated)
    end

    test "a blocking finding is refused however the request is phrased", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      assert {:error, :not_dismissible} =
               Suggestions.dismiss(
                 project.id,
                 owner,
                 feature.id,
                 "missing-users",
                 assessment.version
               )

      assert Repo.get!(ReadinessAssessment, assessment.id).dismissed_ids == []
    end

    test "an unknown finding is refused rather than silently recorded", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      assert {:error, :not_dismissible} =
               Suggestions.dismiss(project.id, owner, feature.id, "invented", assessment.version)

      assert Repo.get!(ReadinessAssessment, assessment.id).dismissed_ids == []
    end

    test "a dismissal against a superseded assessment is rejected", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      assert {:error, :stale_assessment} =
               Suggestions.dismiss(
                 project.id,
                 owner,
                 feature.id,
                 "tighten-copy",
                 assessment.version + 1
               )
    end

    test "a reassessment invalidates a dismissal aimed at the older finding list", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      ReadinessGuidanceDouble.script({:findings, [suggestion("different-suggestion")]})
      {:ok, _replaced} = Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert {:error, :stale_assessment} =
               Suggestions.dismiss(
                 project.id,
                 owner,
                 feature.id,
                 "tighten-copy",
                 assessment.version
               )
    end

    test "two dismissals accumulate rather than replacing each other", %{
      project: project,
      feature: feature,
      owner: owner,
      assessment: assessment
    } do
      ids = ["tighten-copy", "second-suggestion"]

      final =
        Enum.reduce(ids, assessment, fn id, current ->
          {:ok, updated} =
            Suggestions.dismiss(project.id, owner, feature.id, id, current.version)

          updated
        end)

      assert Enum.sort(final.dismissed_ids) == Enum.sort(ids)
      assert ReadinessAssessment.suggestions(final) == []
    end

    test "an outsider and a departed participant are refused", %{
      context: context,
      project: project,
      feature: feature,
      owner_account: owner_account,
      participant: participant,
      assessment: assessment
    } do
      assert {:error, :unauthorized} =
               Suggestions.dismiss(
                 project.id,
                 %{account_id: Ecto.UUID.generate()},
                 feature.id,
                 "tighten-copy",
                 assessment.version
               )

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Suggestions.dismiss(
                 project.id,
                 participant,
                 feature.id,
                 "tighten-copy",
                 assessment.version
               )
    end
  end

  describe "reaching readiness [AC-04, AC-13]" do
    test "a feature with no blocker moves to Ready for development", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      _assessment =
        assess(%{authority: authority, project: project, feature: feature, owner: owner}, [
          suggestion("tighten-copy")
        ])

      assert {:ok, %{applied?: true, results: results}} =
               Suggestions.promote(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 "ready:#{feature.id}"
               )

      assert results.feature.lifecycle_column == "ready_for_development"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "ready_for_development"
    end

    test "readiness is recorded as its own decision in history", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assess(%{authority: authority, project: project, feature: feature, owner: owner}, [])

      {:ok, _promoted} =
        Suggestions.promote(
          authority,
          owner,
          %{project: project, feature: feature},
          "ready:#{feature.id}"
        )

      types = ActivityEntry |> Repo.all() |> Enum.sort_by(& &1.sequence) |> Enum.map(& &1.type)

      assert types == ["readiness_evaluated", "readiness_evaluated"]
    end

    test "a feature with a blocker cannot be promoted [AC-10]", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assess(
        %{authority: authority, project: project, feature: feature, owner: owner},
        mixed_findings()
      )

      assert {:error, :not_ready} =
               Suggestions.promote(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 "ready:#{feature.id}"
               )

      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end

    test "dismissing every suggestion never clears a blocker for promotion", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assessment =
        assess(
          %{authority: authority, project: project, feature: feature, owner: owner},
          mixed_findings()
        )

      {:ok, _dismissed} =
        Suggestions.dismiss(project.id, owner, feature.id, "tighten-copy", assessment.version)

      assert {:error, :not_ready} =
               Suggestions.promote(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 "ready:#{feature.id}"
               )
    end

    test "promotion does not start development [AC-14]", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assess(%{authority: authority, project: project, feature: feature, owner: owner}, [])

      {:ok, _promoted} =
        Suggestions.promote(
          authority,
          owner,
          %{project: project, feature: feature},
          "ready:#{feature.id}"
        )

      # Ready is an invitation, not an action: no run, no attempt, no command.
      assert Repo.aggregate(SddOrchestrator.Delivery.AgentRun, :count) == 0
      assert Repo.aggregate(SddOrchestrator.Delivery.RunCommand, :count) == 0
      assert Repo.get!(Feature, feature.id).lifecycle_column == "ready_for_development"
    end

    test "repeating the promotion is absorbed rather than applied twice", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assess(%{authority: authority, project: project, feature: feature, owner: owner}, [])
      request = {authority, owner, %{project: project, feature: feature}, "ready:#{feature.id}"}

      {a, b, c, d} = request
      assert {:ok, %{applied?: true}} = Suggestions.promote(a, b, c, d)
      assert {:ok, %{applied?: false}} = Suggestions.promote(a, b, c, d)

      assert Repo.get!(Feature, feature.id).lifecycle_column == "ready_for_development"
    end

    test "an outsider cannot promote", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assess(%{authority: authority, project: project, feature: feature, owner: owner}, [])

      assert {:error, :unauthorized} =
               Suggestions.promote(
                 authority,
                 %{account_id: Ecto.UUID.generate()},
                 %{project: project, feature: feature},
                 "ready:#{feature.id}"
               )
    end
  end

  describe "visible findings" do
    test "separates blockers from undismissed suggestions", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assessment =
        assess(
          %{authority: authority, project: project, feature: feature, owner: owner},
          mixed_findings()
        )

      assert %{blockers: [blocker], suggestions: suggestions} = Suggestions.visible(assessment)
      assert blocker["id"] == "missing-users"
      assert length(suggestions) == 2

      {:ok, updated} =
        Suggestions.dismiss(project.id, owner, feature.id, "tighten-copy", assessment.version)

      assert %{blockers: [_still_blocked], suggestions: [remaining]} =
               Suggestions.visible(updated)

      assert remaining["id"] == "second-suggestion"
    end
  end

  defp assess(%{authority: authority, project: project, feature: feature, owner: owner}, findings) do
    ReadinessGuidanceDouble.script({:findings, findings})
    {:ok, assessment} = Readiness.assess(authority, owner, %{project: project, feature: feature})
    assessment
  end

  defp mixed_findings do
    [
      %{
        "id" => "missing-users",
        "category" => "missing",
        "blocking" => true,
        "summary" => "Nobody says who this is for.",
        "explanation" => "Name the people who will use this."
      },
      suggestion("tighten-copy"),
      suggestion("second-suggestion")
    ]
  end

  defp suggestion(id) do
    %{
      "id" => id,
      "category" => "ambiguous",
      "blocking" => false,
      "summary" => "Wording could be clearer.",
      "explanation" => "Consider rewording so the intent is unambiguous."
    }
  end
end
