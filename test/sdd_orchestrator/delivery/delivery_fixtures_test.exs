defmodule SddOrchestrator.DeliveryFixturesTest do
  @moduledoc """
  Proof that seeding a newer approved profile really seeds a newer one.

  A test that asks for a second approved profile and silently gets the first one
  back proves nothing about the contract it believes the run is under. The store
  keeps assessment times to the whole second and breaks a tie on that time with
  a random uuid, so two assessments seeded inside one second once left which of
  them counted as the latest to chance. Approval only reads the latest
  assessment, so the losing draw re-approved the first proposal and appended no
  version at all.
  """
  use SddOrchestrator.DataCase, async: false

  import Ecto.Query

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment

  @second_revision String.duplicate("2", 40)
  @third_revision String.duplicate("3", 40)

  describe "approve_profile!/3" do
    test "appends a second version bound to the newer commit" do
      %{project: project, account: account, profile: first} =
        DeliveryFixtures.delivery_project_fixture()

      assert first.version == 1
      assert first.base_revision == DeliveryFixtures.base_revision()

      second = DeliveryFixtures.approve_profile!(account.id, project, commit: @second_revision)

      assert second.version == 2
      assert second.base_revision == @second_revision

      assert {:ok, in_force} =
               RepositoryAssessments.approved_profile({:hosted, account.id}, project.id)

      assert in_force.version == 2
      assert in_force.base_revision == @second_revision
    end

    test "gives two approvals asked for at one time a second each" do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      pinned = DateTime.add(DateTime.utc_now(), 3_600, :second)

      second =
        DeliveryFixtures.approve_profile!(account.id, project,
          commit: @second_revision,
          now: pinned
        )

      third =
        DeliveryFixtures.approve_profile!(account.id, project,
          commit: @third_revision,
          now: pinned
        )

      assert second.version == 2
      assert second.base_revision == @second_revision
      assert third.version == 3
      assert third.base_revision == @third_revision

      assert {:ok, in_force} =
               RepositoryAssessments.approved_profile({:hosted, account.id}, project.id)

      assert in_force.version == 3
      assert in_force.base_revision == @third_revision

      # The store reads the latest assessment by time, so no two of them may
      # share one second or that read is a coin toss.
      times =
        RepositoryAssessment
        |> where([assessment], assessment.project_id == ^project.id)
        |> select([assessment], assessment.inserted_at)
        |> Repo.all()

      assert length(times) == 3
      assert times |> Enum.uniq() |> length() == 3
    end
  end
end
