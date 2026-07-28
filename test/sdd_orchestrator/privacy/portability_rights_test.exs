defmodule SddOrchestrator.Privacy.PortabilityRightsTest do
  @moduledoc """
  Task 22 proof for verified portability access, correction, erasure,
  restriction, objection, processor, and backup-expiry propagation.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    HostedLocalRepositoryBinding,
    HostedLocalRepositoryBindings,
    ImportAttempt,
    PackageProvenance,
    PackageSection,
    ProjectPackage,
    RestoreDecision,
    RestoreIntake
  }

  alias SddOrchestrator.Privacy.Rights
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationRevision
  }

  alias SddOrchestrator.{SpecificationFixtures, SpecificationStore}

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()
    worker = pair_available_worker(device_workspace.id)

    %{device_workspace: device_workspace, worker: worker}
  end

  test "account and project access export every minimized portability record without ciphertext",
       %{device_workspace: device_workspace, worker: worker} do
    context = hosted_restored_project(device_workspace, worker)
    encrypted_marker = "encrypted-rights-marker-#{System.unique_integer([:positive])}"

    assert {:ok, attempt} =
             RestoreIntake.start(context.workspace, "hosted", encrypted_marker)

    assert {:ok, account_export} = Rights.export_account(context.account.id)
    assert [attempt_export] = account_export.import_attempts
    assert attempt_export.id == attempt.id
    assert attempt_export.status == "uploaded"

    project_export = Enum.find(account_export.projects, &(&1.id == context.project.id))
    assert project_export.repository_identity.repository_id == context.repository_id
    assert project_export.provenance.payload_schema_version == 1
    assert project_export.provenance.restored_at == context.restored_at
    assert project_export.hosted_local_repository_binding.worker_id == worker.id
    assert [specification] = project_export.specifications
    assert length(specification.revisions) == 2

    dump = inspect(account_export)
    refute dump =~ encrypted_marker
    refute dump =~ "encrypted_package"

    assert {:ok, rights_export} =
             Rights.export_portability_project(context.workspace, context.project.id)

    assert rights_export.id == context.project.id
    assert rights_export.propagation.primary_boundary == :hosted
    assert rights_export.propagation.encrypted_backups.maximum_expiry_days == 35
    assert rights_export.propagation.encrypted_backups.restore_scope == :approved_recovery_only

    foreign_workspace = foreign_workspace()

    assert {:error, :not_found} =
             Rights.export_portability_project(foreign_workspace, context.project.id)
  end

  test "corrects hosted and device project names and specifications through their normal stores",
       %{device_workspace: device_workspace, worker: worker} do
    hosted = hosted_restored_project(device_workspace, worker)
    hosted_before = Repo.get!(Project, hosted.project.id)

    assert {:ok, hosted_renamed} =
             Rights.correct_portability_project_name(
               hosted.workspace,
               hosted.project.id,
               "Corrected hosted name"
             )

    assert hosted_renamed.id == hosted_before.id
    assert hosted_renamed.canonical_repository_id == hosted_before.canonical_repository_id
    assert hosted_renamed.name == "Corrected hosted name"

    assert {:error, :not_found} =
             Rights.correct_portability_project_name(
               foreign_workspace(),
               hosted.project.id,
               "Disclosed"
             )

    hosted_current =
      SpecificationStore.get_current(
        hosted.workspace,
        hosted.project.id,
        hosted.specification_id
      )

    assert {:ok, hosted_current} = hosted_current

    assert {:ok, corrected_hosted_specification} =
             Rights.correct_portability_specification(
               hosted.workspace,
               hosted.project.id,
               hosted.specification_id,
               hosted_current.revision.id,
               correction_attrs("corrected hosted")
             )

    assert corrected_hosted_specification.revision.tasks_document == "corrected hosted"

    device = restore_device(device_workspace, "Device rights", "9301")
    device_before = device.project

    assert {:ok, device_renamed} =
             Rights.correct_portability_project_name(
               device_workspace,
               device.project.id,
               "Corrected device name"
             )

    assert device_renamed.id == device_before.id
    assert device_renamed.repository_id == device_before.repository_id
    assert device_renamed.name == "Corrected device name"

    assert {:ok, device_current} =
             SpecificationStore.get_current(
               device_workspace,
               device.project.id,
               device.specification_id
             )

    assert {:ok, corrected_device_specification} =
             Rights.correct_portability_specification(
               device_workspace,
               device.project.id,
               device.specification_id,
               device_current.revision.id,
               correction_attrs("corrected device")
             )

    assert corrected_device_specification.revision.tasks_document == "corrected device"
  end

  test "erasure removes project-bound records and returns processor and backup handoffs",
       %{device_workspace: device_workspace, worker: worker} do
    hosted = hosted_restored_project(device_workspace, worker)
    assert {:ok, attempt} = RestoreIntake.start(hosted.workspace, "hosted", "temporary")

    assert {:ok, hosted_erasure} =
             Rights.erase_portability_project(hosted.workspace, hosted.project.id)

    assert hosted_erasure.action == :erasure
    assert hosted_erasure.propagation.primary_store == :deleted

    assert Enum.all?(
             hosted_erasure.propagation.processors,
             &(&1.action == :delete)
           )

    assert hosted_erasure.propagation.encrypted_backups == %{
             action: :erasure,
             deletion_propagation: :required,
             maximum_expiry_days: 35,
             restore_scope: :approved_recovery_only
           }

    refute Repo.get(Project, hosted.project.id)
    refute Repo.get(PackageProvenance, hosted.project.id)
    refute Repo.get(HostedLocalRepositoryBinding, hosted.project.id)
    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
    assert Repo.get(ImportAttempt, attempt.id)

    assert {:ok, account_erasure} = Rights.erase_account(hosted.account.id)
    assert account_erasure.propagation.encrypted_backups.maximum_expiry_days == 35
    refute Repo.get(ImportAttempt, attempt.id)

    device = restore_device(device_workspace, "Erase device rights", "9302")

    assert {:ok, device_erasure} =
             Rights.erase_portability_project(device_workspace, device.project.id)

    assert device_erasure.deleted_provenance
    assert device_erasure.propagation.primary_boundary == :device

    assert device_erasure.propagation.processors == [
             %{processor: :device_worker, action: :delete}
           ]

    assert {:error, :not_found} = Devices.get_project(device.project.id)
    assert {:error, :not_found} = Devices.get_package_provenance(device.project.id)
  end

  test "restriction and objection require an explicit operator decision without mutation",
       %{device_workspace: device_workspace, worker: worker} do
    hosted = hosted_restored_project(device_workspace, worker)

    for action <- [:restriction, :objection] do
      assert {:ok, assessment} =
               Rights.assess_portability_request(
                 hosted.workspace,
                 hosted.project.id,
                 action
               )

      assert assessment.action == action
      assert assessment.disposition == :verified_operator_assessment_required
      assert assessment.propagation.primary_store == :pending_verified_operator_decision

      assert Enum.all?(
               assessment.propagation.processors,
               &(&1.action == :apply_operator_decision)
             )

      assert assessment.propagation.encrypted_backups.deletion_propagation == :required
      assert Repo.get(Project, hosted.project.id)
      assert Repo.get(PackageProvenance, hosted.project.id)
      assert Repo.get(HostedLocalRepositoryBinding, hosted.project.id)
    end

    assert {:error, :not_found} =
             Rights.assess_portability_request(
               foreign_workspace(),
               hosted.project.id,
               :restriction
             )
  end

  test "device export remains device-authoritative and cross-boundary isolated", %{
    device_workspace: device_workspace
  } do
    device = restore_device(device_workspace, "Device export", "9303")

    assert {:ok, export} =
             Rights.export_portability_project(device_workspace, device.project.id)

    assert export.id == device.project.id
    assert export.repository_identity == %{provider: "github", repository_id: "9303"}
    assert export.hosted_local_repository_binding == nil
    assert export.provenance.payload_schema_version == 1
    assert [specification] = export.specifications
    assert specification.id == device.specification_id
    assert export.propagation.primary_boundary == :device
    assert Repo.aggregate(Project, :count) == 0

    assert {:error, :not_found} =
             Rights.export_portability_project(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               device.project.id
             )

    assert {:error, :not_found} =
             Rights.export_portability_project(
               %PersonalWorkspace{id: Ecto.UUID.generate()},
               device.project.id
             )
  end

  defp hosted_restored_project(device_workspace, worker) do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    repository_id = ProjectsFixtures.local_repository_metadata().fingerprint

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Hosted portability rights #{System.unique_integer([:positive])}",
        workspace_id: workspace.id,
        storage_mode: "hosted",
        repository_provider: "local",
        canonical_repository_id: repository_id
      })
      |> Repo.insert!()

    restored_at = ~U[2026-07-28 12:00:00Z]

    %PackageProvenance{}
    |> PackageProvenance.create_changeset(%{
      project_id: project.id,
      payload_schema_version: 1,
      restored_at: restored_at
    })
    |> Repo.insert!()

    specification_attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, current} =
             SpecificationStore.create(
               workspace,
               project.id,
               specification_attrs,
               actor_ref: "rights-owner"
             )

    assert {:ok, _appended} =
             SpecificationStore.append_revision(
               workspace,
               project.id,
               specification_attrs.id,
               current.revision.id,
               correction_attrs("second hosted revision")
             )

    assert {:ok, %{binding: _binding}} =
             HostedLocalRepositoryBindings.put_validated_binding(
               workspace,
               project.id,
               device_workspace,
               worker.id,
               repository_id
             )

    %{
      account: account,
      project: project,
      repository_id: repository_id,
      restored_at: restored_at,
      specification_id: specification_attrs.id,
      workspace: workspace
    }
  end

  defp restore_device(device_workspace, name, repository_id) do
    specification_id = Ecto.UUID.generate()

    package =
      %ProjectPackage{
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
              "title" => "Restored rights",
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

  defp correction_attrs(tasks) do
    %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "rights-correction",
      documents: %{
        requirements: "# Corrected requirements",
        design: "# Corrected design",
        tasks: tasks
      }
    }
  end

  defp foreign_workspace do
    AccountsFixtures.account_fixture()
    |> ProjectsFixtures.workspace_fixture()
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

  defp store_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "sdd_portability_rights_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, "store.dets")
  end
end
