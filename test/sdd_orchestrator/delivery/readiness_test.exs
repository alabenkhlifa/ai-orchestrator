defmodule SddOrchestrator.Delivery.ReadinessTest do
  @moduledoc """
  Proof for guided requirements and blocking readiness (Task 10).

  Readiness is the gate in front of consequential, costly work, so the tests
  pin the three properties that make the gate real: the verdict is bound to the
  exact revision it judged, a blocker cannot be dismissed or overridden, and
  `Start development` is unavailable — not merely discouraged — while one
  remains.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    Readiness,
    ReadinessAssessment
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  setup do
    restore = ReadinessGuidanceDouble.install()
    on_exit(restore)

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    specification_attrs =
      SpecificationFixtures.specification_attrs(%{
        title: "Delivery",
        documents:
          SpecificationFixtures.documents(%{
            requirements: "# Requirements\n\nThe catalog must be searchable."
          })
      })

    {:ok, current} =
      SpecificationStore.create(
        context.workspace,
        context.project.id,
        specification_attrs,
        actor_ref: "owner"
      )

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      current: current,
      specification_attrs: specification_attrs,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "assessing a revision [AC-09]" do
    test "records the boundary's findings against the exact revision", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature,
      current: current
    } do
      ReadinessGuidanceDouble.script(
        {:findings,
         [
           finding("missing-users", "missing", true, "Nobody says who this is for."),
           finding(
             "tighten-copy",
             "ambiguous",
             false,
             "The empty state wording could be clearer."
           )
         ]}
      )

      assert {:ok, assessment} =
               Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert assessment.revision_id == current.revision.id
      assert assessment.revision_digest == current.revision.content_digest
      assert assessment.specification_id == current.specification.id
      assert length(ReadinessAssessment.findings(assessment)) == 2
    end

    test "explains each finding in plain language with a visible classification", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script(
        {:findings, [finding("missing-users", "missing", true, "Nobody says who this is for.")]}
      )

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert [blocker] = ReadinessAssessment.blockers(assessment)
      assert blocker["blocking"] == true
      assert blocker["category"] == "missing"
      assert blocker["explanation"] =~ "who this is for"
    end

    test "describes the requirement structure a feature is expected to cover" do
      keys = Enum.map(Readiness.guided_structure(), & &1.key)

      assert keys == ~w(outcome users rules done)

      for section <- Readiness.guided_structure() do
        assert is_binary(section.label)
        assert is_binary(section.hint)
      end
    end

    test "replaces the current assessment rather than accumulating verdicts", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script(
        {:findings, [finding("missing-users", "missing", true, "Nobody says who this is for.")]}
      )

      {:ok, first} = Readiness.assess(authority, owner, %{project: project, feature: feature})

      ReadinessGuidanceDouble.script({:findings, []})
      {:ok, second} = Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert second.id == first.id
      assert second.version == first.version + 1
      assert ReadinessAssessment.findings(second) == []
      assert Repo.aggregate(ReadinessAssessment, :count) == 1
    end

    test "records the verdict's shape in history without copying requirement text", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script(
        {:findings,
         [
           finding("missing-users", "missing", true, "Nobody says who this is for."),
           finding("tighten-copy", "ambiguous", false, "Wording could be clearer.")
         ]}
      )

      {:ok, _assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert [entry] = Repo.all(ActivityEntry)
      assert entry.type == "readiness_evaluated"
      assert entry.payload["blocking"] == 1
      assert entry.payload["suggestions"] == 1
      assert entry.payload["ready"] == false

      encoded = entry |> ActivityEntry.to_value() |> Jason.encode!()
      refute encoded =~ "searchable"
      refute encoded =~ "who this is for"
    end

    test "reports a boundary failure rather than an empty verdict", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script({:error, :guidance_timeout})

      assert {:error, :guidance_timeout} =
               Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert Repo.aggregate(ReadinessAssessment, :count) == 0
    end

    test "denies an outsider and never assesses", %{
      authority: authority,
      project: project,
      feature: feature
    } do
      assert {:error, :unauthorized} =
               Readiness.assess(authority, %{account_id: Ecto.UUID.generate()}, %{
                 project: project,
                 feature: feature
               })

      assert Repo.aggregate(ReadinessAssessment, :count) == 0
    end
  end

  describe "blockers keep development unavailable [AC-10]" do
    test "start is unavailable while any blocker remains", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script(
        {:findings, [finding("missing-users", "missing", true, "Nobody says who this is for.")]}
      )

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      refute ReadinessAssessment.start_available?(assessment)
      refute Readiness.start_available?(authority, project.id, owner, feature.id)
    end

    test "start becomes available once every blocker is resolved", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script(
        {:findings, [finding("tighten-copy", "ambiguous", false, "Wording could be clearer.")]}
      )

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert ReadinessAssessment.start_available?(assessment)
      assert Readiness.start_available?(authority, project.id, owner, feature.id)
    end

    test "an absent assessment is not readiness", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      refute Readiness.start_available?(authority, project.id, owner, feature.id)
      assert {:error, :not_found} = Readiness.current(project.id, owner, feature.id)
    end

    test "a verdict about a superseded revision does not authorize starting", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature,
      current: current
    } do
      ReadinessGuidanceDouble.script({:findings, []})

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      assert Readiness.start_available?(authority, project.id, owner, feature.id)

      # Editing the requirements moves the revision, so the earlier verdict
      # judged different text and can no longer authorize a start.
      {:ok, _appended} =
        SpecificationStore.append_revision(
          authority,
          project.id,
          current.specification.id,
          current.revision.id,
          %{
            revision_id: Ecto.UUID.generate(),
            documents:
              SpecificationFixtures.documents(%{
                requirements: "# Requirements\n\nSearchable by name and owner."
              }),
            actor_ref: "owner"
          }
        )

      refute Readiness.start_available?(authority, project.id, owner, feature.id)
      refute ReadinessAssessment.current_for?(assessment, "other-revision", "other-digest")
    end

    test "an outsider cannot read the assessment", %{project: project, feature: feature} do
      assert {:error, :unauthorized} =
               Readiness.current(project.id, %{account_id: Ecto.UUID.generate()}, feature.id)
    end
  end

  describe "a blocker cannot be dismissed [AC-11]" do
    setup %{authority: authority, owner: owner, project: project, feature: feature} do
      ReadinessGuidanceDouble.script(
        {:findings,
         [
           finding("missing-users", "missing", true, "Nobody says who this is for."),
           finding("tighten-copy", "ambiguous", false, "Wording could be clearer.")
         ]}
      )

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      %{assessment: assessment}
    end

    test "a blocking finding is never dismissible", %{assessment: assessment} do
      refute Readiness.dismissible?(assessment, "missing-users")
      assert Readiness.dismissible?(assessment, "tighten-copy")
      refute Readiness.dismissible?(assessment, "no-such-finding")
    end

    test "recording a dismissal cannot remove a blocker from the blocker list", %{
      assessment: assessment
    } do
      # Even if a dismissal names the blocker, the blocker list ignores
      # dismissals entirely — there is no code path that hides one.
      dismissed =
        assessment
        |> ReadinessAssessment.dismissal_changeset(
          ["missing-users", "tighten-copy"],
          assessment.version
        )
        |> Repo.update!()

      assert Enum.map(ReadinessAssessment.blockers(dismissed), & &1["id"]) == ["missing-users"]
      refute ReadinessAssessment.start_available?(dismissed)
    end

    test "a dismissal offered against a superseded assessment is rejected", %{
      assessment: assessment
    } do
      changeset =
        ReadinessAssessment.dismissal_changeset(
          assessment,
          ["tighten-copy"],
          assessment.version + 1
        )

      refute changeset.valid?
      assert "is stale" in errors_on(changeset).version
    end

    test "a dismissed suggestion stops counting while the blocker stays", %{
      assessment: assessment
    } do
      dismissed =
        assessment
        |> ReadinessAssessment.dismissal_changeset(["tighten-copy"], assessment.version)
        |> Repo.update!()

      assert ReadinessAssessment.suggestions(dismissed) == []
      assert length(ReadinessAssessment.blockers(dismissed)) == 1
    end
  end

  describe "no duplicate specification persistence" do
    test "the assessment stores identity and digest, never the requirement text", %{
      authority: authority,
      owner: owner,
      project: project,
      feature: feature
    } do
      ReadinessGuidanceDouble.script({:findings, []})

      {:ok, assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      stored = Repo.get!(ReadinessAssessment, assessment.id)
      encoded = Jason.encode!(%{findings: stored.findings, revision: stored.revision_id})

      refute encoded =~ "searchable"
      assert stored.revision_digest =~ ~r/\A[0-9a-f]+\z/
    end
  end

  defp finding(id, category, blocking, explanation) do
    %{
      "id" => id,
      "category" => category,
      "blocking" => blocking,
      "summary" => String.slice(explanation, 0, 60),
      "explanation" => explanation
    }
  end
end
