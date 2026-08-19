defmodule SddOrchestrator.ProjectAssistant.DeletionLifecycleTest do
  @moduledoc """
  specs/12-project-assistant Task 9 focused proof: redaction, retention,
  deletion, rights, and prohibited-use controls (AC-19, AC-20, AC-21).

  Covers immediate participant deletion also clearing the boundary
  confirmation, scheduled 30-day-inactivity retention, immediate
  participation-loss cleanup on the retention sweep's very next pass
  (rather than waiting on inactivity), hosted project deletion's existing
  cascade, the device project-deletion purge this task adds, and rights
  export including project-assistant conversation content — for both
  hosted and device authorities.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.Participation.ProjectParticipant

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    PackageProvenance,
    PackageSection,
    ProjectPackage,
    RestoreDecision
  }

  alias SddOrchestrator.Privacy.{Retention, Rights}

  alias SddOrchestrator.ProjectAssistant.{
    AssistantBoundaryConfirmation,
    DeviceConversationPurge,
    DeviceProjectAssistantConversation,
    ProjectAssistantCitation,
    ProjectAssistantConversation,
    ProjectAssistantTurn
  }

  alias SddOrchestrator.{ProjectAssistantBoundaryStore, ProjectAssistantStore}
  alias SddOrchestrator.Specifications.SpecificationLifecycle

  @now ~U[2026-08-15 12:00:00Z]
  @thirty_one_days_ago DateTime.add(@now, -31 * 24 * 60 * 60, :second)
  @one_day_ago DateTime.add(@now, -24 * 60 * 60, :second)

  describe "hosted authority" do
    setup do
      DeliveryFixtures.delivery_project_fixture()
    end

    test "deleting a conversation also deletes its boundary confirmation", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, actor, "question")

      insert_confirmation!(project.id, account.id, @now)
      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 1

      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, actor)

      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 0
      assert Repo.aggregate(ProjectAssistantConversation, :count) == 0

      # Idempotent: deleting again (no conversation, no confirmation) still succeeds.
      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, actor)
    end

    test "a conversation inactive for 30+ days is pruned with its turns, citations, and confirmation",
         %{project: project, account: account} do
      conversation = insert_conversation!(project.id, account.id, @thirty_one_days_ago)
      insert_turn!(conversation, project.id)
      insert_confirmation!(project.id, account.id, @thirty_one_days_ago)

      assert %{
               expired_project_assistant_conversations: 1,
               expired_assistant_boundary_confirmations: 1
             } = Retention.prune_project_assistant_conversations(@now)

      assert Repo.aggregate(ProjectAssistantConversation, :count) == 0
      assert Repo.aggregate(ProjectAssistantTurn, :count) == 0
      assert Repo.aggregate(ProjectAssistantCitation, :count) == 0
    end

    test "a conversation active within 30 days survives the sweep", %{
      project: project,
      account: account
    } do
      insert_conversation!(project.id, account.id, @one_day_ago)

      assert %{expired_project_assistant_conversations: 0} =
               Retention.prune_project_assistant_conversations(@now)

      assert Repo.aggregate(ProjectAssistantConversation, :count) == 1
    end

    test "a departed participant's conversation is pruned immediately on the next sweep, regardless of recent activity",
         %{project: project, identity: identity, participant_actor: participant_actor} do
      # Recent activity — would survive the 30-day rule alone.
      conversation = insert_conversation!(project.id, participant_actor.account_id, @now)
      insert_confirmation!(project.id, participant_actor.account_id, @now)

      depart_participant!(project.id, identity)

      assert %{
               expired_project_assistant_conversations: 1,
               expired_assistant_boundary_confirmations: 1
             } = Retention.prune_project_assistant_conversations(@now)

      refute Repo.get(ProjectAssistantConversation, conversation.id)
    end

    test "the owner's conversation is never treated as departed", %{
      project: project,
      account: account
    } do
      insert_conversation!(project.id, account.id, @now)
      insert_confirmation!(project.id, account.id, @now)

      assert %{
               expired_project_assistant_conversations: 0,
               expired_assistant_boundary_confirmations: 0
             } = Retention.prune_project_assistant_conversations(@now)
    end

    test "a boundary confirmation for a still-current, active participant is never pruned purely on its own age (AC-06)",
         %{project: project, account: account} do
      # No conversation at all yet (confirmed before ever asking a
      # question) and an old `confirmed_at` — must still survive, because a
      # confirmation stays valid until the disclosed boundary changes, not
      # on a calendar timer.
      insert_confirmation!(project.id, account.id, @thirty_one_days_ago)

      assert %{expired_assistant_boundary_confirmations: 0} =
               Retention.prune_project_assistant_conversations(@now)

      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 1
    end

    test "re-running the sweep is idempotent", %{project: project, account: account} do
      insert_conversation!(project.id, account.id, @thirty_one_days_ago)

      assert %{expired_project_assistant_conversations: 1} =
               Retention.prune_project_assistant_conversations(@now)

      assert %{expired_project_assistant_conversations: 0} =
               Retention.prune_project_assistant_conversations(@now)
    end

    test "hosted project deletion cascades every project-assistant table without a separate purge call",
         %{project: project, workspace: workspace, account: account, owner_actor: actor} do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, actor, "question")
      insert_confirmation!(project.id, account.id, @now)

      insert!(PackageProvenance, %{
        project_id: project.id,
        payload_schema_version: 1,
        restored_at: @now
      })

      assert {:ok, _result} = SpecificationLifecycle.delete_project(workspace, project.id)

      assert Repo.aggregate(ProjectAssistantConversation, :count) == 0
      assert Repo.aggregate(ProjectAssistantTurn, :count) == 0
      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 0
    end

    test "export_account/1 includes the account's own project-assistant conversation content", %{
      project: project,
      workspace: workspace,
      account: account,
      owner_actor: actor
    } do
      {:ok, _} =
        ProjectAssistantStore.append_turn(workspace, project.id, actor, "what is current?")

      assert {:ok, export} = Rights.export_account(account.id)
      assert [conversation] = export.project_assistant_conversations
      assert conversation.project_id == project.id
      assert [turn] = conversation.turns
      assert turn.question_text == "what is current?"
    end

    test "erase_account/2 cascades project-assistant conversations through the account foreign key",
         %{project: project, workspace: workspace, account: account, owner_actor: actor} do
      {:ok, _} =
        ProjectAssistantStore.append_turn(workspace, project.id, actor, "before erasure")

      assert {:ok, _result} = Rights.erase_account(account.id)
      assert Repo.aggregate(ProjectAssistantConversation, :count) == 0
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "project_assistant_deletion_lifecycle_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device assistant deletion project",
          repository_fingerprint:
            "device-assistant-deletion-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{workspace: workspace, project: project}
    end

    test "a device conversation inactive for 30+ days is pruned", %{
      project: project,
      workspace: workspace
    } do
      put_device_conversation!(project.id, workspace.id, @thirty_one_days_ago)

      assert %{expired_device_project_assistant_conversations: 1} =
               Retention.prune_project_assistant_conversations(@now)

      assert {:ok, nil, []} = ProjectAssistantStore.list_history(workspace, project.id, %{})
    end

    test "a device conversation active within 30 days survives the sweep", %{
      project: project,
      workspace: workspace
    } do
      put_device_conversation!(project.id, workspace.id, @one_day_ago)

      assert %{expired_device_project_assistant_conversations: 0} =
               Retention.prune_project_assistant_conversations(@now)

      assert {:ok, %DeviceProjectAssistantConversation{}, _turns} =
               ProjectAssistantStore.list_history(workspace, project.id, %{})
    end

    test "deleting a device conversation also deletes its boundary confirmation", %{
      project: project,
      workspace: workspace
    } do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, %{}, "question")

      assert {:ok, _confirmation} =
               ProjectAssistantBoundaryStore.confirm(
                 workspace,
                 project.id,
                 %{},
                 "digest-abc",
                 1,
                 @now
               )

      assert {:ok, %{}} =
               ProjectAssistantBoundaryStore.get_confirmation(workspace, project.id, %{})

      assert :ok = ProjectAssistantStore.delete_conversation(workspace, project.id, %{})

      assert {:ok, nil} =
               ProjectAssistantBoundaryStore.get_confirmation(workspace, project.id, %{})
    end

    test "DeviceConversationPurge.purge/1 tombstones every project-assistant delivery kind", %{
      project: project,
      workspace: workspace
    } do
      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project.id, %{}, "question")

      assert {:ok, _confirmation} =
               ProjectAssistantBoundaryStore.confirm(
                 workspace,
                 project.id,
                 %{},
                 "digest-abc",
                 1,
                 @now
               )

      counts = DeviceConversationPurge.purge(project.id)

      assert counts.project_assistant_conversation == 1
      assert counts.project_assistant_turn == 1
      assert counts.assistant_boundary_confirmation == 1

      assert {:ok, nil, []} = ProjectAssistantStore.list_history(workspace, project.id, %{})

      assert {:ok, nil} =
               ProjectAssistantBoundaryStore.get_confirmation(workspace, project.id, %{})

      # Idempotent: purging an already-purged project purges nothing further.
      assert DeviceConversationPurge.purge(project.id) == %{
               project_assistant_conversation: 0,
               project_assistant_turn: 0,
               project_assistant_citation: 0,
               assistant_boundary_confirmation: 0,
               project_context_projection: 0
             }
    end

    test "erasing a restored device project purges project-assistant data through Rights.erase_portability_project/2",
         %{workspace: workspace} do
      pair_available_worker(workspace.id)
      restored = restore_device(workspace, "Restored assistant project", "9401")
      project_id = restored.project.id

      {:ok, _} = ProjectAssistantStore.append_turn(workspace, project_id, %{}, "question")

      assert {:ok, _confirmation} =
               ProjectAssistantBoundaryStore.confirm(
                 workspace,
                 project_id,
                 %{},
                 "digest-abc",
                 1,
                 @now
               )

      turn_id_before_erasure =
        Devices.list_delivery(project_id, :project_assistant_turn)
        |> Enum.reject(&(&1["deleted"] == true))
        |> List.first()
        |> Map.fetch!("id")

      assert {:ok, result} = Rights.erase_portability_project(workspace, project_id)
      assert result.propagation.primary_boundary == :device

      assert {:error, :not_found} = Devices.get_project(project_id)

      # The purge ran (and tombstoned) before `Devices.delete_project/1`
      # removed the project row itself, proving ordering rather than only
      # end-state: the turn this test wrote is now a tombstone, not absent.
      {:ok, tombstoned_turn} =
        Devices.get_delivery(project_id, :project_assistant_turn, turn_id_before_erasure)

      assert tombstoned_turn["deleted"] == true

      assert Devices.list_delivery(project_id, :project_assistant_conversation)
             |> Enum.all?(&(&1["deleted"] == true))

      # The project row itself is gone, so the ordinary authorized
      # `ProjectAssistantBoundaryStore` read path correctly refuses (there
      # is no longer a project to authorize against); the raw delivery
      # record is checked directly instead, the same way the turn above is.
      assert {:error, :unauthorized} =
               ProjectAssistantBoundaryStore.get_confirmation(workspace, project_id, %{})

      {:ok, tombstoned_confirmation} =
        Devices.get_delivery(project_id, :assistant_boundary_confirmation, workspace.id)

      assert tombstoned_confirmation["deleted"] == true
    end
  end

  defp insert_conversation!(project_id, account_id, last_activity_at) do
    %ProjectAssistantConversation{}
    |> ProjectAssistantConversation.create_changeset(%{
      project_id: project_id,
      account_id: account_id,
      last_activity_at: last_activity_at
    })
    |> Repo.insert!()
  end

  defp insert_turn!(conversation, project_id) do
    %ProjectAssistantTurn{}
    |> ProjectAssistantTurn.create_changeset(%{
      conversation_id: conversation.id,
      project_id: project_id,
      sequence: 1,
      question_text: "a question"
    })
    |> Repo.insert!()
  end

  defp insert_confirmation!(project_id, account_id, confirmed_at) do
    %AssistantBoundaryConfirmation{}
    |> AssistantBoundaryConfirmation.create_changeset(%{
      project_id: project_id,
      account_id: account_id,
      boundary_digest: "digest-#{System.unique_integer([:positive])}",
      boundary_version: 1,
      confirmed_at: confirmed_at
    })
    |> Repo.insert!()
  end

  defp depart_participant!(project_id, identity) do
    ProjectParticipant
    |> Repo.get_by!(project_id: project_id, hosted_identity_id: identity.hosted_identity.id)
    |> ProjectParticipant.departure_changeset(%{departure_reason: "left"})
    |> Repo.update!()
  end

  defp put_device_conversation!(project_id, workspace_id, last_activity_at) do
    conversation = %DeviceProjectAssistantConversation{
      id: workspace_id,
      project_id: project_id,
      workspace_id: workspace_id,
      last_activity_at: last_activity_at,
      state_version: 1,
      inserted_at: last_activity_at,
      updated_at: last_activity_at
    }

    {:ok, _applied} =
      Devices.commit_delivery(project_id, [
        {:put, :project_assistant_conversation, workspace_id,
         DeviceProjectAssistantConversation.to_value(conversation), nil}
      ])

    conversation
  end

  defp insert!(schema, attrs) do
    struct(schema, attrs) |> Repo.insert!()
  end

  # Mirrors `SddOrchestrator.Privacy.PortabilityRightsTest`'s own private
  # `restore_device/3` helper exactly, so `Rights.erase_portability_project/2`'s
  # device branch (`PackageProvenances.get/2` requiring a genuine
  # `DeviceRestore`-created provenance, not a hand-inserted hosted
  # `PackageProvenance` row) is exercised the same real way that test file
  # already proves works.
  defp restore_device(device_workspace, name, repository_id) do
    specification_id = Ecto.UUID.generate()

    package = %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{"id" => Ecto.UUID.generate(), "name" => name}
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => "github", "repository_id" => repository_id}
      },
      specifications: %PackageSection{
        name: :specifications,
        version: 1,
        content: [
          %{
            "id" => specification_id,
            "title" => "Restored assistant lifecycle",
            "requirements" => "# Requirements",
            "design" => "# Design",
            "tasks" => "# Tasks"
          }
        ]
      }
    }

    decision = %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: name,
      repository_provider: "github",
      repository_id: repository_id,
      checked_boundaries: [:device]
    }

    assert {:ok, result} =
             DeviceRestore.restore(device_workspace, package, decision,
               idempotency_key: Ecto.UUID.generate()
             )

    Map.put(result, :specification_id, specification_id)
  end

  defp pair_available_worker(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end
end
