defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantStoreTest do
  @moduledoc """
  specs/12-project-assistant Task 1 focused proof: conversation identity,
  persistence, and authorization for both the hosted and device authorities.

  Covers AC-02 (fail-closed, no-existence-disclosure authorization for open,
  read-history, and delete), AC-03 (independent per-participant private
  history, never shared project activity), and AC-23 (no shared-activity
  projection).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.ActivityEntry
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Participation.ProjectParticipant
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectAssistant.{ProjectAssistantConversation, ProjectAssistantTurn}
  alias SddOrchestrator.ProjectAssistantStore

  describe "hosted authority" do
    setup do
      DeliveryFixtures.delivery_project_fixture()
    end

    test "creates exactly one conversation per participant and project", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor
    } do
      assert {:ok, conversation1} =
               ProjectAssistantStore.open_conversation(workspace, project.id, owner_actor)

      assert {:ok, conversation2} =
               ProjectAssistantStore.open_conversation(workspace, project.id, owner_actor)

      assert conversation1.id == conversation2.id
      assert Repo.aggregate(ProjectAssistantConversation, :count) == 1
    end

    test "preserves independent histories for two participants and orders turns", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      participant_actor: participant_actor
    } do
      assert {:ok, {_c, _t}} =
               ProjectAssistantStore.append_turn(workspace, project.id, owner_actor, "owner q1")

      assert {:ok, {owner_conversation, _t}} =
               ProjectAssistantStore.append_turn(workspace, project.id, owner_actor, "owner q2")

      assert {:ok, {participant_conversation, _t}} =
               ProjectAssistantStore.append_turn(
                 workspace,
                 project.id,
                 participant_actor,
                 "participant q1"
               )

      assert owner_conversation.id != participant_conversation.id

      assert {:ok, ^owner_conversation, owner_turns} =
               ProjectAssistantStore.list_history(workspace, project.id, owner_actor)

      assert {:ok, ^participant_conversation, participant_turns} =
               ProjectAssistantStore.list_history(workspace, project.id, participant_actor)

      assert Enum.map(owner_turns, & &1.question_text) == ["owner q1", "owner q2"]
      assert Enum.map(owner_turns, & &1.sequence) == [1, 2]
      assert Enum.map(participant_turns, & &1.question_text) == ["participant q1"]
      assert Enum.map(participant_turns, & &1.sequence) == [1]

      assert DateTime.compare(owner_conversation.last_activity_at, owner_conversation.inserted_at) in [
               :gt,
               :eq
             ]
    end

    test "returns an empty history for an authorized participant who has not opened a conversation",
         %{project: project, workspace: workspace, participant_actor: participant_actor} do
      assert {:ok, nil, []} =
               ProjectAssistantStore.list_history(workspace, project.id, participant_actor)
    end

    test "rejects a stale (removed) participant's open, read-history, and delete without disclosure",
         %{
           project: project,
           workspace: workspace,
           participant_actor: participant_actor,
           identity: identity
         } do
      {:ok, _} =
        ProjectAssistantStore.append_turn(
          workspace,
          project.id,
          participant_actor,
          "before removal"
        )

      participant =
        Repo.get_by!(ProjectParticipant,
          project_id: project.id,
          hosted_identity_id: identity.hosted_identity.id
        )

      participant
      |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
      |> Repo.update!()

      assert {:error, :unauthorized} =
               ProjectAssistantStore.open_conversation(workspace, project.id, participant_actor)

      assert {:error, :unauthorized} =
               ProjectAssistantStore.list_history(workspace, project.id, participant_actor)

      assert {:error, :unauthorized} =
               ProjectAssistantStore.delete_conversation(workspace, project.id, participant_actor)

      # The private history the removed participant built before departure is
      # untouched and inaccessible, not silently exposed or wiped by the
      # denial itself.
      assert Repo.aggregate(ProjectAssistantConversation, :count) == 1
    end

    test "rejects an absent identity and a cross-project identity identically", %{
      project: project,
      workspace: workspace
    } do
      other = ParticipationFixtures.invited_identity_fixture()

      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      %{project: other_project, participant_actor: other_project_actor} =
        DeliveryFixtures.delivery_project_fixture()

      absent = ProjectAssistantStore.open_conversation(workspace, project.id, absent_actor)

      cross_project =
        ProjectAssistantStore.open_conversation(workspace, project.id, other_project_actor)

      unknown_project =
        ProjectAssistantStore.open_conversation(workspace, Ecto.UUID.generate(), absent_actor)

      assert absent == {:error, :unauthorized}
      assert cross_project == {:error, :unauthorized}
      assert unknown_project == {:error, :unauthorized}
      assert absent == cross_project
      assert absent == unknown_project

      refute other_project == project
    end

    test "deletes the conversation and its turns immediately, allowing a fresh start", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor
    } do
      {:ok, {conversation, _turn}} =
        ProjectAssistantStore.append_turn(workspace, project.id, owner_actor, "question")

      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, owner_actor)

      refute Repo.get(ProjectAssistantConversation, conversation.id)
      assert Repo.aggregate(ProjectAssistantTurn, :count) == 0

      # Idempotent: deleting again still succeeds without disclosure.
      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, owner_actor)

      assert {:ok, nil, []} =
               ProjectAssistantStore.list_history(workspace, project.id, owner_actor)
    end

    test "creates no shared project activity", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      participant_actor: participant_actor
    } do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, owner_actor, "owner q")

      {:ok, _} =
        ProjectAssistantStore.append_turn(workspace, project.id, participant_actor, "p q")

      ProjectAssistantStore.delete_conversation(workspace, project.id, owner_actor)

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "device authority" do
    setup do
      path = store_path()
      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device assistant project",
          repository_fingerprint:
            "device-assistant-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{workspace: workspace, project: project}
    end

    test "creates exactly one conversation for the device's implicit participant", %{
      project: project,
      workspace: workspace
    } do
      assert {:ok, conversation1} =
               ProjectAssistantStore.open_conversation(workspace, project.id, %{})

      assert {:ok, conversation2} =
               ProjectAssistantStore.open_conversation(workspace, project.id, %{})

      assert conversation1.id == conversation2.id
    end

    test "orders turns and advances last activity atomically, matching hosted behavior", %{
      project: project,
      workspace: workspace
    } do
      assert {:ok, {c1, t1}} =
               ProjectAssistantStore.append_turn(workspace, project.id, %{}, "first question")

      assert {:ok, {c2, t2}} =
               ProjectAssistantStore.append_turn(workspace, project.id, %{}, "second question")

      assert t1.sequence == 1
      assert t2.sequence == 2
      assert DateTime.compare(c2.last_activity_at, c1.last_activity_at) in [:gt, :eq]

      assert {:ok, _conversation, turns} =
               ProjectAssistantStore.list_history(workspace, project.id, %{})

      assert Enum.map(turns, & &1.question_text) == ["first question", "second question"]
      assert Enum.map(turns, & &1.sequence) == [1, 2]
    end

    test "returns an empty history before any turn is appended", %{
      project: project,
      workspace: workspace
    } do
      assert {:ok, nil, []} = ProjectAssistantStore.list_history(workspace, project.id, %{})
    end

    test "rejects a stale device workspace and a cross-project identity identically", %{
      project: project,
      workspace: workspace
    } do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      wrong_workspace = ProjectAssistantStore.open_conversation(other_workspace, project.id, %{})

      wrong_project =
        ProjectAssistantStore.open_conversation(workspace, Ecto.UUID.generate(), %{})

      assert wrong_workspace == {:error, :unauthorized}
      assert wrong_project == {:error, :unauthorized}
      assert wrong_workspace == wrong_project
    end

    test "deletes the conversation and its turns immediately, allowing a fresh start", %{
      project: project,
      workspace: workspace
    } do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, %{}, "question")

      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, %{})
      assert {:ok, nil, []} = ProjectAssistantStore.list_history(workspace, project.id, %{})

      # Idempotent, and a fresh conversation starts turn ordering over.
      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, %{})

      assert {:ok, {_conversation, turn}} =
               ProjectAssistantStore.append_turn(workspace, project.id, %{}, "new question")

      assert turn.sequence == 1
    end

    test "creates no shared project activity", %{project: project, workspace: workspace} do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, %{}, "question")
      ProjectAssistantStore.delete_conversation(workspace, project.id, %{})

      assert Devices.list_delivery(project.id, :activity) == []
    end
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "project_assistant_device_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
