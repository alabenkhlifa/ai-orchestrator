defmodule SddOrchestrator.Privacy.SpecificationGovernanceTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.{DeploymentPrivacyProfile, ProcessingInventory, Rights}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationAuthorization,
    SpecificationAuthorizationPolicy,
    SpecificationLifecycle,
    SpecificationRevision
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

  defmodule ParticipantPolicy do
    @behaviour SpecificationAuthorizationPolicy

    @impl true
    def authorize_project(%{project_id: project_id, role: :participant}, project_id), do: :ok
    def authorize_project(_authority, _project_id), do: {:error, :not_found}
  end

  defmodule DenyPolicy do
    @behaviour SpecificationAuthorizationPolicy

    @impl true
    def authorize_project(_authority, _project_id), do: {:error, :not_found}
  end

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()

    %{
      account: account,
      device_workspace: device_workspace,
      project: project,
      workspace: workspace
    }
  end

  test "inventories every persisted specification field with its approved purpose and boundary" do
    purposes = ProcessingInventory.specification_field_purposes()

    assert Enum.sort(Map.keys(purposes.project_specification)) ==
             Enum.sort(ProjectSpecification.__schema__(:fields))

    assert Enum.sort(Map.keys(purposes.specification_revision)) ==
             Enum.sort(SpecificationRevision.__schema__(:fields))

    record =
      Enum.find(
        ProcessingInventory.records(),
        &(&1.activity == :project_specification_storage)
      )

    assert record.lawful_basis == :contract
    assert Enum.any?(record.processors, &String.contains?(&1, "Hosting database"))
    assert Enum.any?(record.processors, &String.contains?(&1, "Device worker"))
    assert record.retention =~ "30 days"
    assert record.retention =~ "35 days"
    refute ProcessingInventory.analytics?()

    minimized =
      purposes
      |> inspect()
      |> String.downcase()

    refute minimized =~ "path"
    refute minimized =~ "credential"
    refute minimized =~ "repository"
    refute minimized =~ "storage_mode"
  end

  test "exports complete hosted revision history and erases every authoritative row", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, current} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               attrs,
               actor_ref: "owner"
             )

    append = %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "owner",
      documents: SpecificationFixtures.documents(%{tasks: "completed"})
    }

    assert {:ok, _appended} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               current.specification.id,
               current.revision.id,
               append
             )

    assert {:ok, export} = Rights.export_account(context.account.id)
    assert [project] = export.projects
    assert [specification] = project.specifications
    assert specification.id == attrs.id
    assert specification.current_revision_id == append.revision_id
    assert Enum.map(specification.revisions, & &1.id) == [attrs.revision_id, append.revision_id]
    assert Enum.map(specification.revisions, & &1.actor_ref) == ["owner", "owner"]
    assert List.last(specification.revisions).tasks_document == "completed"

    assert {:ok, %{account_id: _account_id}} = Rights.erase_account(context.account.id)
    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "authorized hosted and device project deletion removes specification data", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, _hosted} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    foreign_workspace =
      AccountsFixtures.account_fixture()
      |> ProjectsFixtures.workspace_fixture()

    assert {:error, :not_found} =
             SpecificationLifecycle.delete_project(foreign_workspace, context.project.id)

    assert Repo.aggregate(ProjectSpecification, :count) == 1

    assert {:ok, %{project_id: hosted_id}} =
             SpecificationLifecycle.delete_project(context.workspace, context.project.id)

    assert hosted_id == context.project.id
    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0

    device_project = device_project("governance-device")

    assert {:ok, _device} =
             SpecificationStore.create(context.device_workspace, device_project.id, attrs)

    assert {:error, :not_found} =
             SpecificationLifecycle.delete_project(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               device_project.id
             )

    assert Devices.specification_count(device_project.id) == 1

    assert {:ok, %{project_id: device_id, deleted_specifications: 1}} =
             SpecificationLifecycle.delete_project(
               context.device_workspace,
               device_project.id
             )

    assert device_id == device_project.id
    assert {:error, :not_found} = Devices.get_project(device_project.id)
  end

  test "security outcomes contain no supplied content or stable identifiers", context do
    specification_id = Ecto.UUID.generate()
    revision_id = Ecto.UUID.generate()
    secret_title = "private-title-marker"
    secret_document = "private-document-marker ../secret/path"
    actor = "person@example.test"

    attrs = %{
      id: specification_id,
      revision_id: revision_id,
      title: secret_title,
      documents: %{
        requirements: secret_document,
        design: secret_document,
        tasks: secret_document
      }
    }

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 SpecificationStore.create(
                   %PersonalWorkspace{id: Ecto.UUID.generate()},
                   context.project.id,
                   attrs,
                   actor_ref: actor
                 )
      end)

    assert log =~ "[specification_security]"
    assert log =~ "event=create"
    assert log =~ "outcome=denied_or_missing"
    refute log =~ specification_id
    refute log =~ revision_id
    refute log =~ context.project.id
    refute log =~ secret_title
    refute log =~ secret_document
    refute log =~ actor
  end

  test "keeps documents out of indexes, caches, analytics tables, and retention identifiers" do
    {:ok, %{rows: index_rows}} =
      Repo.query("""
      SELECT indexdef
      FROM pg_indexes
      WHERE tablename IN ('project_specifications', 'specification_revisions')
      """)

    index_text = index_rows |> List.flatten() |> Enum.join(" ") |> String.downcase()
    refute index_text =~ "requirements_document"
    refute index_text =~ "design_document"
    refute index_text =~ "tasks_document"
    refute index_text =~ "content_digest"
    refute index_text =~ "actor_ref"

    {:ok, %{rows: table_rows}} =
      Repo.query("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")

    table_names = table_rows |> List.flatten() |> Enum.map(&String.downcase/1)

    refute Enum.any?(
             table_names,
             &Regex.match?(~r/specification.*(cache|snapshot|analytic|telemetry)/, &1)
           )

    assert DeploymentPrivacyProfile.retention_requirements() == %{
             operational_security_logs_days: 30,
             encrypted_rolling_backups_days: 35
           }
  end

  test "uses the current snapshot directly as the Slice 06 restoration contract", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, _current} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    assert {:ok, snapshot} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    assert {:ok, %{project_id: project_id}} =
             SpecificationLifecycle.delete_project(context.workspace, context.project.id)

    project_changeset =
      Project.registration_changeset(
        %Project{id: project_id},
        %{
          name: "Restored project",
          workspace_id: context.workspace.id,
          storage_mode: "hosted",
          lifecycle_state: "active"
        }
      )

    transaction = Multi.insert(Multi.new(), :project, project_changeset)
    key = Ecto.UUID.generate()

    assert {:ok, transaction} =
             SpecificationStore.prepare_restore(
               context.workspace,
               transaction,
               snapshot.specifications,
               idempotency_key: key
             )

    assert {:ok, changes} = Repo.transaction(transaction)
    assert [restored] = changes[{:specification_restore, key}]
    assert restored.specification.id == attrs.id
    assert restored.revision.id == attrs.revision_id
  end

  test "keeps owner access additive while exposing the Slice 07 participant policy seam",
       context do
    participant = %{project_id: context.project.id, role: :participant}

    assert {:ok, participant_project} =
             SpecificationAuthorization.hosted_project(
               participant,
               context.project.id,
               ParticipantPolicy
             )

    assert participant_project.id == context.project.id

    assert {:error, :not_found} =
             SpecificationAuthorization.hosted_project(
               %{project_id: context.project.id, role: :removed},
               context.project.id,
               ParticipantPolicy
             )

    assert {:ok, owner_project} =
             SpecificationAuthorization.hosted_project(
               context.workspace,
               context.project.id,
               DenyPolicy
             )

    assert owner_project.id == context.project.id
  end

  defp device_project(fingerprint) do
    {:ok, project} =
      Devices.register_project(%{
        name: fingerprint,
        repository_fingerprint: fingerprint,
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    project
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "specification_governance_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
