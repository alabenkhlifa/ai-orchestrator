defmodule SddOrchestrator.Delivery.FeatureLifecycleTest do
  use SddOrchestrator.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias SddOrchestrator.Delivery.{Feature, Features}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

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

    :ok
  end

  describe "creation" do
    test "starts one feature in Draft with its recorded creator" do
      %{project: project, participant_actor: actor, identity: identity} = delivery_project()

      assert {:ok, feature} = Features.create(project.id, actor, %{title: "  Search filters  "})

      assert feature.project_id == project.id
      assert feature.title == "Search filters"
      assert feature.creator_account_id == identity.account.id
      assert is_nil(feature.assigned_account_id)
      assert feature.lifecycle_column == "draft"
      assert feature.status == "none"
      assert feature.state_version == 1
    end

    test "rejects a blank or oversized title" do
      %{project: project, owner_actor: actor} = delivery_project()

      for invalid <- ["", "   ", String.duplicate("t", 201)] do
        assert {:error, changeset} = Features.create(project.id, actor, %{title: invalid})
        assert errors_on(changeset).title != []
      end
    end

    test "denies a non-member and scopes every feature to one project" do
      %{project: project, owner_actor: actor} = delivery_project()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      assert {:error, :unauthorized} =
               Features.create(project.id, outsider_actor, %{title: "Intruder"})

      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})
      %{project: other_project, owner_actor: other_actor} = delivery_project()

      assert {:error, :unauthorized} = Features.fetch(other_project.id, actor, feature.id)
      assert {:error, :not_found} = Features.fetch(other_project.id, other_actor, feature.id)
      assert {:ok, ^feature} = Features.fetch(project.id, actor, feature.id)
    end
  end

  describe "legal transitions" do
    test "walks the approved lifecycle and bumps the state version each time" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      path = [
        {"ready_for_development", 2},
        {"in_development", 3},
        {"ready_for_review", 4},
        {"done", 5}
      ]

      feature =
        Enum.reduce(path, feature, fn {to, version}, current ->
          assert {:ok, moved} = Features.transition(project.id, actor, current, to)
          assert moved.lifecycle_column == to
          assert moved.state_version == version
          assert moved.status == "none"
          moved
        end)

      assert feature.lifecycle_column == "done"
    end

    test "supports review rejection and cancellation recovery" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      {:ok, ready} = Features.transition(project.id, actor, feature, "ready_for_development")
      {:ok, running} = Features.transition(project.id, actor, ready, "in_development")
      {:ok, review} = Features.transition(project.id, actor, running, "ready_for_review")

      assert {:ok, rejected} = Features.transition(project.id, actor, review, "in_development")
      assert rejected.lifecycle_column == "in_development"

      assert {:ok, recovered} =
               Features.transition(project.id, actor, rejected, "ready_for_development")

      assert recovered.lifecycle_column == "ready_for_development"

      {:ok, restarted} = Features.transition(project.id, actor, recovered, "in_development")
      assert {:ok, dropped} = Features.transition(project.id, actor, restarted, "draft")
      assert dropped.lifecycle_column == "draft"
    end
  end

  describe "illegal transitions" do
    test "rejects every move the transition table does not contain" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      for illegal <- ["in_development", "ready_for_review", "done", "draft"] do
        assert {:error, :illegal_transition} =
                 Features.transition(project.id, actor, feature, illegal)
      end

      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
      assert Repo.get!(Feature, feature.id).state_version == 1
    end

    test "never moves a feature back out of Done" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      done =
        ["ready_for_development", "in_development", "ready_for_review", "done"]
        |> Enum.reduce(feature, fn to, current ->
          {:ok, moved} = Features.transition(project.id, actor, current, to)
          moved
        end)

      for to <- Feature.columns() do
        assert {:error, :illegal_transition} = Features.transition(project.id, actor, done, to)
      end

      assert Feature.transitions()["done"] == []
    end

    test "rejects an unknown column name" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      assert {:error, :illegal_transition} =
               Features.transition(project.id, actor, feature, "archived")
    end
  end

  describe "expected state version" do
    test "rejects a superseded version and keeps the committed state" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      {:ok, moved} = Features.transition(project.id, actor, feature, "ready_for_development")
      assert moved.state_version == 2

      # A stale tab still holds version 1 and offers its own transition.
      assert {:error, :stale_state} =
               Features.transition(project.id, actor, feature, "ready_for_development",
                 expected_state_version: 1
               )

      current = Repo.get!(Feature, feature.id)
      assert current.lifecycle_column == "ready_for_development"
      assert current.state_version == 2
    end
  end

  describe "visible status" do
    test "shows Blocked and Failed without leaving In development" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      {:ok, ready} = Features.transition(project.id, actor, feature, "ready_for_development")
      {:ok, running} = Features.transition(project.id, actor, ready, "in_development")

      assert {:ok, blocked} = Features.put_status(project.id, actor, running, "blocked")
      assert blocked.status == "blocked"
      assert blocked.lifecycle_column == "in_development"

      assert {:ok, failed} = Features.put_status(project.id, actor, blocked, "failed")
      assert failed.status == "failed"
      assert failed.lifecycle_column == "in_development"

      assert {:ok, cleared} = Features.put_status(project.id, actor, failed, "none")
      assert cleared.status == "none"
    end

    test "refuses a status outside In development in the domain and the database" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      assert {:error, :illegal_transition} =
               Features.put_status(project.id, actor, feature, "blocked")

      assert_raise Postgrex.Error, ~r/features_status_placement/, fn ->
        SQL.query!(
          Repo,
          "UPDATE features SET status = 'failed' WHERE id = $1",
          [Ecto.UUID.dump!(feature.id)]
        )
      end
    end
  end

  describe "device-adapter value shape" do
    test "round trips one feature without Ecto" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})
      {:ok, running} = Features.transition(project.id, actor, feature, "ready_for_development")

      value = Feature.to_value(running)

      assert Map.keys(value) |> Enum.sort() == [
               "assigned_account_id",
               "creator_account_id",
               "id",
               "lifecycle_column",
               "project_id",
               "state_version",
               "status",
               "title"
             ]

      assert {:ok, restored} = Feature.from_value(value)
      assert restored.id == running.id
      assert restored.lifecycle_column == "ready_for_development"
      assert restored.state_version == running.state_version
      assert Feature.to_value(restored) == value
    end

    test "rejects a malformed device value" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})
      value = Feature.to_value(feature)

      for invalid <- [
            Map.put(value, "lifecycle_column", "archived"),
            Map.put(value, "status", "paused"),
            Map.put(value, "state_version", 0),
            Map.put(value, "title", nil),
            Map.delete(value, "id"),
            "not a map"
          ] do
        assert {:error, :invalid_feature_value} = Feature.from_value(invalid)
      end
    end
  end

  describe "authorization" do
    test "a removed participant can no longer read or move a feature" do
      %{project: project, account: owner_account, participant_actor: actor, identity: identity} =
        delivery_project()

      feature = DeliveryFixtures.feature_fixture(project, identity.account)

      assert {:ok, _fetched} = Features.fetch(project.id, actor, feature.id)

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:error, :unauthorized} = Features.fetch(project.id, actor, feature.id)

      assert {:error, :unauthorized} =
               Features.transition(project.id, actor, feature, "ready_for_development")

      assert {:error, :unauthorized} = Features.create(project.id, actor, %{title: "After"})
      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end
  end

  describe "rollback" do
    test "a failed transition inside a transaction leaves no change" do
      %{project: project, owner_actor: actor} = delivery_project()
      feature = DeliveryFixtures.feature_fixture(project, %{id: actor.account_id})

      result =
        Repo.transaction(fn ->
          {:ok, moved} = Features.transition(project.id, actor, feature, "ready_for_development")

          case Features.transition(project.id, actor, moved, "done") do
            {:ok, done} -> done
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      assert {:error, :illegal_transition} = result

      current = Repo.get!(Feature, feature.id)
      assert current.lifecycle_column == "draft"
      assert current.state_version == 1
    end
  end

  defp delivery_project, do: DeliveryFixtures.delivery_project_fixture()
end
