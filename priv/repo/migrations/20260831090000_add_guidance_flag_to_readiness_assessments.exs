defmodule SddOrchestrator.Repo.Migrations.AddGuidanceFlagToReadinessAssessments do
  use Ecto.Migration

  # specs/41-feature-delivery-from-the-ui Task 3.
  #
  # A verdict now says whether a guidance model took part in it. Without that,
  # an assessment with no model findings and an assessment a model judged as
  # clean look identical, and the page would have to guess which one it is
  # showing.
  #
  # The column is additive and nullable. Every row written before this migration
  # could only exist when an adapter answered, so a null reads as `configured`
  # and no backfill is needed.
  def change do
    alter table(:readiness_assessments) do
      add :guidance, :string
    end
  end
end
