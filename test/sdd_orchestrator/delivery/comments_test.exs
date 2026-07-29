defmodule SddOrchestrator.Delivery.CommentsTest do
  @moduledoc """
  Proof for participant feature comments (Task 46).

  A comment is free text written by a person, which makes it the most likely
  place for a pasted token or address to enter project history. It is also the
  one contribution a participant can make directly to a feature's activity, so
  authorization, project scope, ordering, and attribution all have to hold on
  exactly the same terms as machine-written entries.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ActivityEntry, Comments}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
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
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      context: context,
      project: context.project,
      feature: feature,
      owner_account: context.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "adding a comment [AC-42]" do
    test "appends one entry in project order under the acting participant", %{
      project: project,
      feature: feature,
      participant: participant,
      context: context
    } do
      assert {:ok, entry} =
               Comments.add(project.id, participant, feature.id, "This needs a mobile layout.")

      assert entry.type == "comment"
      assert entry.actor_kind == "participant"
      assert entry.actor_account_id == context.identity.account.id
      assert entry.payload["body"] == "This needs a mobile layout."
      assert entry.sequence == 1
    end

    test "keeps comments in one ordered history with other activity", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      DeliveryFixtures.activity_fixture(project, feature, %{type: "progress"})
      {:ok, first} = Comments.add(project.id, owner, feature.id, "Looks close.")
      DeliveryFixtures.activity_fixture(project, feature, %{type: "progress"})
      {:ok, second} = Comments.add(project.id, participant, feature.id, "Agreed.")

      assert [first.sequence, second.sequence] == [2, 4]
    end

    test "trims surrounding whitespace", %{project: project, feature: feature, owner: owner} do
      assert {:ok, entry} = Comments.add(project.id, owner, feature.id, "  spaced out  ")
      assert entry.payload["body"] == "spaced out"
    end

    test "attributes the comment by project display name, never an address", %{
      project: project,
      feature: feature,
      participant: participant,
      context: context
    } do
      {:ok, entry} = Comments.add(project.id, participant, feature.id, "Ready for review soon.")

      label = Participation.member_profile(project.id, context.identity.account.id).display_name

      assert entry.actor_account_id == context.identity.account.id
      refute label =~ "@"

      encoded = entry |> ActivityEntry.to_value() |> Jason.encode!()
      refute encoded =~ "@example.com"
    end
  end

  describe "content limits and redaction" do
    test "rejects an empty or whitespace-only comment", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      assert {:error, :empty_comment} = Comments.add(project.id, owner, feature.id, "")
      assert {:error, :empty_comment} = Comments.add(project.id, owner, feature.id, "   \n ")
      assert {:error, :empty_comment} = Comments.add(project.id, owner, feature.id, nil)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "rejects a comment beyond the approved length", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      oversized = String.duplicate("x", Comments.max_body_bytes() + 1)

      assert {:error, :comment_too_long} = Comments.add(project.id, owner, feature.id, oversized)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "refuses a pasted credential rather than storing and redacting it", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      credentials = [
        "use sk-abcdefghijklmnopqrstuvwxyz012345",
        "token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "github_pat_11ABCDEFG0abcdefghijklmnop",
        "-----BEGIN RSA PRIVATE KEY-----",
        "key AKIAIOSFODNN7EXAMPLE"
      ]

      for body <- credentials do
        assert {:error, :redacted_content} = Comments.add(project.id, owner, feature.id, body)
      end

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "refuses an address so one participant cannot expose another", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      assert {:error, :redacted_content} =
               Comments.add(project.id, owner, feature.id, "ask alex@example.com about this")

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "duplicate submission" do
    test "the same text twice in a row is one comment", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      assert {:ok, _first} = Comments.add(project.id, owner, feature.id, "Double clicked.")

      assert {:error, :duplicate_comment} =
               Comments.add(project.id, owner, feature.id, "Double clicked.")

      assert Repo.aggregate(ActivityEntry, :count) == 1
    end

    test "the same text after another comment is a real comment", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      {:ok, _first} = Comments.add(project.id, owner, feature.id, "Ping")
      {:ok, _other} = Comments.add(project.id, participant, feature.id, "Pong")

      assert {:ok, _repeat} = Comments.add(project.id, owner, feature.id, "Ping")
      assert Repo.aggregate(ActivityEntry, :count) == 3
    end

    test "two people may say the same thing", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      {:ok, _first} = Comments.add(project.id, owner, feature.id, "Agreed.")

      assert {:ok, _second} = Comments.add(project.id, participant, feature.id, "Agreed.")
    end
  end

  describe "authorization and scope" do
    test "an outsider cannot comment or learn the feature exists", %{
      project: project,
      feature: feature
    } do
      assert {:error, :unauthorized} =
               Comments.add(project.id, %{account_id: Ecto.UUID.generate()}, feature.id, "hello")

      assert {:error, :unauthorized} = Comments.add(project.id, %{}, feature.id, "hello")
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "a departed participant cannot comment", %{
      project: project,
      feature: feature,
      context: context,
      owner_account: owner_account,
      participant: participant
    } do
      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Comments.add(project.id, participant, feature.id, "still here?")

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "cannot comment on another project's feature", %{owner: owner, feature: feature} do
      other = DeliveryFixtures.delivery_project_fixture()

      assert {:error, :unauthorized} =
               Comments.add(other.project.id, owner, feature.id, "wrong project")
    end

    test "an unknown feature reports not found without exposing anything", %{
      project: project,
      owner: owner
    } do
      assert {:error, :not_found} =
               Comments.add(project.id, owner, Ecto.UUID.generate(), "nowhere")
    end
  end

  describe "listing" do
    test "returns only comments, in order, for an authorized member", %{
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      DeliveryFixtures.activity_fixture(project, feature, %{type: "progress"})
      {:ok, _first} = Comments.add(project.id, owner, feature.id, "One")
      {:ok, _second} = Comments.add(project.id, participant, feature.id, "Two")

      assert {:ok, comments} = Comments.list(project.id, participant, feature.id)
      assert Enum.map(comments, & &1.payload["body"]) == ["One", "Two"]
    end

    test "is denied for an outsider", %{project: project, feature: feature} do
      assert {:error, :unauthorized} =
               Comments.list(project.id, %{account_id: Ecto.UUID.generate()}, feature.id)
    end

    test "never returns another feature's comments", %{
      project: project,
      feature: feature,
      owner: owner,
      owner_account: owner_account
    } do
      other = DeliveryFixtures.feature_fixture(project, owner_account)
      {:ok, _mine} = Comments.add(project.id, owner, feature.id, "Mine")
      {:ok, _theirs} = Comments.add(project.id, owner, other.id, "Theirs")

      assert {:ok, [only]} = Comments.list(project.id, owner, feature.id)
      assert only.payload["body"] == "Mine"
    end
  end
end
