defmodule SddOrchestrator.Delivery.ActivityTest do
  @moduledoc """
  Proof for ordered feature activity (Task 17).

  Activity is the record a human uses to decide whether an agent run can be
  trusted, so the properties under test are the ones that make it trustworthy:
  it is ordered by the transaction rather than by a clock, it cannot be
  rewritten after the fact, it never carries a raw provider stream or a
  credential-shaped field, and it is unreadable to anyone who is not a current
  participant.
  """
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi
  alias SddOrchestrator.Delivery.{Activity, ActivityEntry, Feature}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      context: context,
      project: context.project,
      feature: feature,
      account: context.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "ordering" do
    test "assigns authoritative positions from one per feature", %{
      project: project,
      feature: feature
    } do
      first = DeliveryFixtures.activity_fixture(project, feature)
      second = DeliveryFixtures.activity_fixture(project, feature)

      assert first.sequence == 1
      assert second.sequence == 2
    end

    test "orders each feature independently", %{
      project: project,
      feature: feature,
      account: account
    } do
      other = DeliveryFixtures.feature_fixture(project, account)

      DeliveryFixtures.activity_fixture(project, feature)
      DeliveryFixtures.activity_fixture(project, feature)
      entry = DeliveryFixtures.activity_fixture(project, other)

      assert entry.sequence == 1
    end

    test "orders by sequence, not by the recorded occurrence clock", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      later = DateTime.utc_now()
      earlier = DateTime.add(later, -3600, :second)

      DeliveryFixtures.activity_fixture(project, feature, %{occurred_at: later, type: "progress"})

      DeliveryFixtures.activity_fixture(project, feature, %{occurred_at: earlier, type: "comment"})

      assert {:ok, [first, second]} = Activity.list(project.id, owner, feature.id)
      assert [first.type, second.type] == ["progress", "comment"]
      assert [first.sequence, second.sequence] == [1, 2]
    end

    test "two concurrent appends never share a position", %{project: project, feature: feature} do
      parent = self()

      results =
        for _each <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Activity.append(%{
              project_id: project.id,
              feature_id: feature.id,
              actor_kind: "system",
              type: "progress",
              payload: %{}
            })
          end)
        end
        |> Enum.map(&Task.await/1)

      inserted = Enum.count(results, &match?({:ok, _entry}, &1))
      rejected = Enum.count(results, &match?({:error, _changeset}, &1))

      # Either both serialize into distinct positions, or the loser is rejected
      # and retries. What must never happen is two rows at one position.
      assert inserted + rejected == 2
      sequences = ActivityEntry |> Repo.all() |> Enum.map(& &1.sequence)
      assert length(Enum.uniq(sequences)) == length(sequences)
    end
  end

  describe "immutability" do
    test "the database rejects an update even outside the changeset path", %{
      project: project,
      feature: feature
    } do
      entry = DeliveryFixtures.activity_fixture(project, feature)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(
          from(e in ActivityEntry, where: e.id == ^entry.id),
          set: [type: "comment"]
        )
      end

      assert Repo.get!(ActivityEntry, entry.id).type == entry.type
    end

    test "exposes no update changeset" do
      refute function_exported?(ActivityEntry, :update_changeset, 2)
      refute function_exported?(ActivityEntry, :changeset, 2)
    end

    test "deletion stays available so project deletion and retention still work", %{
      project: project,
      feature: feature
    } do
      entry = DeliveryFixtures.activity_fixture(project, feature)

      assert {:ok, _deleted} = Repo.delete(entry)
      refute Repo.get(ActivityEntry, entry.id)
    end
  end

  describe "actor and type" do
    test "a participant entry names its account", %{
      project: project,
      feature: feature,
      account: account
    } do
      entry =
        DeliveryFixtures.activity_fixture(project, feature, %{
          actor_kind: "participant",
          actor_account_id: account.id,
          type: "comment"
        })

      assert entry.actor_kind == "participant"
      assert entry.actor_account_id == account.id
    end

    test "an agent or system entry can never be attributed to a person", %{
      project: project,
      feature: feature,
      account: account
    } do
      for kind <- ~w(agent system) do
        changeset =
          ActivityEntry.append_changeset(%ActivityEntry{}, %{
            project_id: project.id,
            feature_id: feature.id,
            actor_kind: kind,
            actor_account_id: account.id,
            type: "progress",
            sequence: 1
          })

        refute changeset.valid?
        assert errors_on(changeset).actor_account_id
      end
    end

    test "a participant entry without an account is rejected", %{
      project: project,
      feature: feature
    } do
      changeset =
        ActivityEntry.append_changeset(%ActivityEntry{}, %{
          project_id: project.id,
          feature_id: feature.id,
          actor_kind: "participant",
          type: "comment",
          sequence: 1
        })

      refute changeset.valid?
      assert errors_on(changeset).actor_account_id
    end

    test "rejects an unknown actor kind or activity type", %{
      project: project,
      feature: feature
    } do
      base = %{project_id: project.id, feature_id: feature.id, sequence: 1}

      bad_kind =
        ActivityEntry.append_changeset(
          %ActivityEntry{},
          Map.merge(base, %{actor_kind: "robot", type: "progress"})
        )

      bad_type =
        ActivityEntry.append_changeset(
          %ActivityEntry{},
          Map.merge(base, %{actor_kind: "system", type: "whatever"})
        )

      refute bad_kind.valid?
      refute bad_type.valid?
      assert errors_on(bad_kind).actor_kind
      assert errors_on(bad_type).type
    end

    test "covers the slice's activity vocabulary" do
      for type <- ~w(progress comment question_asked question_answered evidence_recorded
                     preview_updated run_completed run_failed run_canceled review_approved
                     review_rejected assignment_changed) do
        assert type in ActivityEntry.types()
      end
    end
  end

  describe "payload minimization" do
    test "rejects a raw provider stream, transcript, or credential field", %{
      project: project,
      feature: feature
    } do
      for key <- ActivityEntry.forbidden_payload_keys() do
        changeset = payload_changeset(project, feature, %{key => "anything"})

        refute changeset.valid?, "#{key} was accepted into activity"
        assert errors_on(changeset).payload
      end
    end

    test "rejects a forbidden field nested inside the payload", %{
      project: project,
      feature: feature
    } do
      nested = payload_changeset(project, feature, %{"result" => %{"stdout" => "..."}})
      in_list = payload_changeset(project, feature, %{"items" => [%{"api_key" => "sk-1"}]})

      refute nested.valid?
      refute in_list.valid?
    end

    test "rejects an oversized payload", %{project: project, feature: feature} do
      oversized = String.duplicate("x", ActivityEntry.max_payload_bytes() + 1)
      changeset = payload_changeset(project, feature, %{"note" => oversized})

      refute changeset.valid?
      assert errors_on(changeset).payload
    end

    test "accepts a minimized normalized payload", %{project: project, feature: feature} do
      entry =
        DeliveryFixtures.activity_fixture(project, feature, %{
          type: "evidence_recorded",
          payload: %{"check" => "mix test", "outcome" => "passed", "duration_ms" => 1200}
        })

      assert entry.payload["check"] == "mix test"
      assert entry.payload["outcome"] == "passed"
    end
  end

  describe "transaction contribution" do
    test "appends inside the caller's transaction and rolls back with it", %{
      project: project,
      feature: feature
    } do
      result =
        Multi.new()
        |> Activity.append_multi(:activity, %{
          project_id: project.id,
          feature_id: feature.id,
          actor_kind: "system",
          type: "run_started",
          payload: %{}
        })
        |> Multi.run(:boom, fn _repo, _changes -> {:error, :injected} end)
        |> Repo.transaction()

      assert {:error, :boom, :injected, _changes} = result
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "names a record created earlier in the same transaction", %{
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, %{activity: entry}} =
        Multi.new()
        |> Multi.insert(
          :feature,
          Feature.create_changeset(%Feature{}, %{
            project_id: project.id,
            title: "Composed",
            creator_account_id: account.id
          })
        )
        |> Activity.append_multi(:activity, fn %{feature: created} ->
          %{
            project_id: project.id,
            feature_id: created.id,
            actor_kind: "system",
            type: "run_started",
            payload: %{}
          }
        end)
        |> Repo.transaction()

      assert entry.sequence == 1
      refute entry.feature_id == feature.id
    end
  end

  describe "authorization and pagination" do
    test "a current participant reads the feature's history", %{
      project: project,
      feature: feature,
      participant: participant
    } do
      DeliveryFixtures.activity_fixture(project, feature)

      assert {:ok, [entry]} = Activity.list(project.id, participant, feature.id)
      assert entry.feature_id == feature.id
    end

    test "an outsider is denied without learning the project exists", %{
      project: project,
      feature: feature
    } do
      DeliveryFixtures.activity_fixture(project, feature)

      assert {:error, :unauthorized} =
               Activity.list(project.id, %{account_id: Ecto.UUID.generate()}, feature.id)

      assert {:error, :unauthorized} = Activity.list(project.id, %{}, feature.id)
    end

    test "never returns another project's activity", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)
      DeliveryFixtures.activity_fixture(other.project, other_feature)
      DeliveryFixtures.activity_fixture(project, feature)

      assert {:ok, entries} = Activity.list(project.id, owner, feature.id)
      assert Enum.map(entries, & &1.feature_id) == [feature.id]
    end

    test "pages forward by sequence with a capped limit", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      for _each <- 1..5, do: DeliveryFixtures.activity_fixture(project, feature)

      assert {:ok, page_one} = Activity.list(project.id, owner, feature.id, limit: 2)
      assert Enum.map(page_one, & &1.sequence) == [1, 2]

      assert {:ok, page_two} =
               Activity.list(project.id, owner, feature.id, limit: 2, after_sequence: 2)

      assert Enum.map(page_two, & &1.sequence) == [3, 4]

      assert {:ok, capped} =
               Activity.list(project.id, owner, feature.id, limit: Activity.max_limit() + 100)

      assert length(capped) == 5
    end

    test "recent returns the newest first", %{project: project, feature: feature, owner: owner} do
      for _each <- 1..3, do: DeliveryFixtures.activity_fixture(project, feature)

      assert {:ok, entries} = Activity.recent(project.id, owner, feature.id)
      assert Enum.map(entries, & &1.sequence) == [3, 2, 1]
    end

    test "a malformed feature identifier reads as empty rather than crashing", %{
      project: project,
      owner: owner
    } do
      assert {:ok, []} = Activity.list(project.id, owner, "not-a-uuid")
    end
  end

  describe "device-adapter value shape" do
    test "round-trips through its plain value", %{project: project, feature: feature} do
      entry =
        DeliveryFixtures.activity_fixture(project, feature, %{
          type: "comment",
          payload: %{"body" => "looks right"}
        })

      assert {:ok, restored} = entry |> ActivityEntry.to_value() |> ActivityEntry.from_value()

      assert restored.id == entry.id
      assert restored.sequence == entry.sequence
      assert restored.type == "comment"
      assert restored.payload == %{"body" => "looks right"}
    end

    test "an unusable value is rejected rather than partially restored" do
      assert {:error, :invalid_activity_value} = ActivityEntry.from_value(%{"type" => "nope"})
      assert {:error, :invalid_activity_value} = ActivityEntry.from_value(%{})
      assert {:error, :invalid_activity_value} = ActivityEntry.from_value("entry")
    end
  end

  defp payload_changeset(project, feature, payload) do
    ActivityEntry.append_changeset(%ActivityEntry{}, %{
      project_id: project.id,
      feature_id: feature.id,
      actor_kind: "system",
      type: "progress",
      sequence: 1,
      payload: payload
    })
  end
end
