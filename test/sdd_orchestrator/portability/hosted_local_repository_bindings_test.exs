defmodule SddOrchestrator.Portability.HostedLocalRepositoryBindingsTest do
  @moduledoc """
  Task 26 proof for the minimized hosted local-worker binding foundation.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{LocalWorker, Pairing}

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    HostedLocalRepositoryBindings
  }

  alias SddOrchestrator.Privacy.Rights
  alias SddOrchestrator.Projects.Project

  setup do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    repository_id = portable_identifier()
    project = local_project_fixture(personal_workspace, repository_id)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    worker = available_worker_fixture(device_workspace)

    %{
      account: account,
      personal_workspace: personal_workspace,
      project: project,
      repository_id: repository_id,
      device_workspace: device_workspace,
      worker: worker
    }
  end

  test "persists exactly the approved fields and project and worker references" do
    assert HostedLocalRepositoryBinding.__schema__(:fields) |> Enum.sort() ==
             [:last_validated_at, :project_id, :worker_id]

    assert HostedLocalRepositoryBinding.__schema__(:associations) |> Enum.sort() ==
             [:project, :worker]

    forbidden_fields = [
      :account_id,
      :workspace_id,
      :device_workspace_id,
      :canonical_repository_id,
      :repository_path,
      :credential,
      :device_label,
      :os_family,
      :os_major,
      :app_version,
      :protocol_version,
      :inserted_at,
      :updated_at
    ]

    for field <- forbidden_fields do
      refute field in HostedLocalRepositoryBinding.__schema__(:fields)
    end
  end

  test "creates one scoped binding and retains it idempotently", context do
    validated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, %{binding: first, outcome: :created}} =
             put_binding(context, validated_at)

    assert first.project_id == context.project.id
    assert first.worker_id == context.worker.id
    assert first.last_validated_at == validated_at

    later = DateTime.add(validated_at, 1, :second)

    assert {:ok, %{binding: retained, outcome: :retained}} =
             put_binding(context, later)

    assert retained.project_id == first.project_id
    assert retained.worker_id == first.worker_id
    assert retained.last_validated_at == later
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1

    assert {:ok, %{binding: state_binding, state: :connected}} =
             HostedLocalRepositoryBindings.connection_state(
               context.personal_workspace,
               context.project.id,
               now: validated_at
             )

    assert state_binding.project_id == context.project.id
  end

  test "requires the owning personal workspace and selected worker's device workspace", context do
    foreign_personal_workspace = account_fixture() |> workspace_fixture()
    foreign_device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             HostedLocalRepositoryBindings.put_validated_binding(
               foreign_personal_workspace,
               context.project.id,
               context.device_workspace,
               context.worker.id,
               context.repository_id
             )

    assert {:error, :unauthorized_worker} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               foreign_device_workspace,
               context.worker.id,
               context.repository_id
             )

    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "requires a hosted local project with a portable exact repository identity", context do
    other_project = project_fixture(context.personal_workspace)

    assert {:error, :invalid_project_provider} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               other_project.id,
               context.device_workspace,
               context.worker.id,
               context.repository_id
             )

    legacy_project =
      local_project_fixture(
        context.personal_workspace,
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      )

    assert {:error, :invalid_repository_identity} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               legacy_project.id,
               context.device_workspace,
               context.worker.id,
               legacy_project.canonical_repository_id
             )

    assert {:error, :repository_mismatch} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               context.device_workspace,
               context.worker.id,
               portable_identifier()
             )

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "rejects unavailable and revoked workers", context do
    unavailable_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    unavailable_worker = paired_worker_fixture(unavailable_workspace)

    assert {:error, :worker_unavailable} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               unavailable_workspace,
               unavailable_worker.id,
               context.repository_id
             )

    assert {:ok, revoked_worker} = Pairing.revoke_worker(context.worker)

    assert {:error, :unauthorized_worker} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               context.device_workspace,
               revoked_worker.id,
               context.repository_id
             )

    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "replaces atomically only after successful exact revalidation", context do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, %{binding: original}} = put_binding(context, now)

    replacement = available_worker_fixture(context.device_workspace)

    assert {:error, :repository_mismatch} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               context.device_workspace,
               replacement.id,
               portable_identifier(),
               validated_at: DateTime.add(now, 1, :second)
             )

    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id ==
             original.worker_id

    assert {:ok, %{binding: replaced, outcome: :replaced}} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               context.project.id,
               context.device_workspace,
               replacement.id,
               context.repository_id,
               validated_at: DateTime.add(now, 2, :second)
             )

    assert replaced.worker_id == replacement.id
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
  end

  test "derives temporary unavailability without rewriting the binding", context do
    validated_at = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, %{binding: binding}} = put_binding(context, validated_at)

    later =
      DateTime.add(
        validated_at,
        SddOrchestrator.Devices.WorkerDiscovery.staleness_seconds() + 1,
        :second
      )

    assert {:ok, %{binding: unavailable, state: :temporarily_unavailable}} =
             HostedLocalRepositoryBindings.connection_state(
               context.personal_workspace,
               context.project.id,
               now: later
             )

    assert unavailable.project_id == binding.project_id
    assert unavailable.worker_id == binding.worker_id
    assert unavailable.last_validated_at == binding.last_validated_at
    assert Repo.get!(HostedLocalRepositoryBinding, binding.project_id) == binding
  end

  test "explicit disconnect is scoped and idempotent", context do
    assert {:ok, %{binding: _binding}} = put_binding(context)
    foreign_personal_workspace = account_fixture() |> workspace_fixture()

    assert {:error, :not_found} =
             HostedLocalRepositoryBindings.disconnect(
               foreign_personal_workspace,
               context.project.id
             )

    assert Repo.get(HostedLocalRepositoryBinding, context.project.id)

    assert {:ok, :disconnected} =
             HostedLocalRepositoryBindings.disconnect(
               context.personal_workspace,
               context.project.id
             )

    assert {:ok, :disconnected} =
             HostedLocalRepositoryBindings.disconnect(
               context.personal_workspace,
               context.project.id
             )

    assert {:ok, %{binding: nil, state: :disconnected}} =
             HostedLocalRepositoryBindings.connection_state(
               context.personal_workspace,
               context.project.id
             )
  end

  test "worker revocation deletes every binding to that worker", context do
    second_account = account_fixture()
    second_workspace = workspace_fixture(second_account)
    second_project = local_project_fixture(second_workspace, portable_identifier())

    assert {:ok, %{binding: _binding}} = put_binding(context)

    assert {:ok, %{binding: _binding}} =
             HostedLocalRepositoryBindings.put_validated_binding(
               second_workspace,
               second_project.id,
               context.device_workspace,
               context.worker.id,
               second_project.canonical_repository_id
             )

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 2
    assert {:ok, _revoked} = Pairing.revoke_worker(context.worker)
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 0
  end

  test "project erasure cascades and account erasure cannot leave a binding", context do
    assert {:ok, %{binding: _binding}} = put_binding(context)
    Repo.delete!(context.project)
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

    replacement_project =
      local_project_fixture(context.personal_workspace, portable_identifier())

    assert {:ok, %{binding: _binding}} =
             HostedLocalRepositoryBindings.put_validated_binding(
               context.personal_workspace,
               replacement_project.id,
               context.device_workspace,
               context.worker.id,
               replacement_project.canonical_repository_id
             )

    assert {:ok, %{account_id: account_id}} = Rights.erase_account(context.account.id)
    assert account_id == context.account.id
    assert Repo.get(HostedLocalRepositoryBinding, replacement_project.id) == nil
  end

  test "service termination deletes all bindings without deleting projects or workers", context do
    assert {:ok, %{binding: _binding}} = put_binding(context)

    assert {:ok, 1} =
             HostedLocalRepositoryBindings.disconnect_all_for_service_termination()

    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
    assert Repo.get(Project, context.project.id)
    assert Repo.get(LocalWorker, context.worker.id)

    assert {:ok, 0} =
             HostedLocalRepositoryBindings.disconnect_all_for_service_termination()
  end

  test "the database enforces one binding per project", context do
    assert {:ok, %{binding: _binding}} = put_binding(context)
    replacement = available_worker_fixture(context.device_workspace)

    assert {:error, changeset} =
             %HostedLocalRepositoryBinding{}
             |> HostedLocalRepositoryBinding.changeset(%{
               project_id: context.project.id,
               worker_id: replacement.id,
               last_validated_at: DateTime.utc_now()
             })
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).project_id
    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
  end

  defp put_binding(context, validated_at \\ DateTime.utc_now()) do
    HostedLocalRepositoryBindings.put_validated_binding(
      context.personal_workspace,
      context.project.id,
      context.device_workspace,
      context.worker.id,
      context.repository_id,
      validated_at: validated_at
    )
  end

  defp local_project_fixture(personal_workspace, repository_id) do
    %Project{}
    |> Project.changeset(%{
      name: "local-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  defp available_worker_fixture(device_workspace) do
    worker = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    worker
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
