defmodule SddOrchestrator.DeliveryFixtures do
  @moduledoc "Test fixtures for feature delivery."

  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  @doc """
  Creates one hosted project with an owner profile and one active participant.

  Returns the project together with the actor maps both members use for
  authorization.
  """
  def delivery_project_fixture do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Member")
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

  @doc "Creates one feature in `Draft`."
  def feature_fixture(project, creator_account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %Feature{}
    |> Feature.create_changeset(%{
      project_id: project.id,
      title: Map.get(attrs, :title, unique_title()),
      creator_account_id: creator_account.id,
      assigned_account_id: Map.get(attrs, :assigned_account_id)
    })
    |> Repo.insert!()
  end

  def unique_title(prefix \\ "Feature"),
    do: "#{prefix} #{System.unique_integer([:positive])}"
end
