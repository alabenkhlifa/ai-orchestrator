defmodule SddOrchestrator.Portability.RestoreIntakeTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Portability
  alias SddOrchestrator.Portability.{BackupSnapshot, PackageEncryption, RestoreIntake}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    %{store_path: path}
  end

  test "hosted intake is authority-bound and encrypted again at rest" do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Hosted source")
    encrypted = encrypted_backup(workspace, project, "hosted phrase")

    assert {:ok, attempt} = RestoreIntake.start(workspace, "hosted", encrypted)
    assert attempt.destination == "hosted"
    assert attempt.status == "uploaded"
    assert attempt.encrypted_package == encrypted

    raw =
      Repo.query!(
        "SELECT encrypted_package FROM import_attempts WHERE id = $1",
        [Ecto.UUID.dump!(attempt.id)]
      ).rows

    assert [[stored]] = raw
    refute stored == encrypted
    refute stored =~ encrypted

    other_workspace =
      AccountsFixtures.account_fixture() |> ProjectsFixtures.workspace_fixture()

    assert {:error, :not_found} = RestoreIntake.get(other_workspace, attempt.id)
    assert {:ok, _owned} = RestoreIntake.get(workspace, attempt.id)
  end

  test "device intake remains in the device store and is vault-sealed at rest", %{
    store_path: path
  } do
    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device source",
        repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
        status: "connected"
      })

    encrypted = encrypted_backup(workspace, project, "device phrase")
    assert {:ok, attempt} = RestoreIntake.start(workspace, "device", encrypted)
    assert Repo.aggregate(Portability.ImportAttempt, :count) == 0
    assert {:ok, owned} = RestoreIntake.get(workspace, attempt.id)
    assert owned.encrypted_package == encrypted

    {:ok, table} =
      :dets.open_file(:restore_intake_inspection,
        file: String.to_charlist(path),
        access: :read
      )

    assert [{{:import_attempt, _id}, stored}] =
             :dets.lookup(table, {:import_attempt, attempt.id})

    :ok = :dets.close(table)
    refute stored.encrypted_package == encrypted
    refute stored.encrypted_package =~ encrypted
  end

  test "successful validation returns plaintext only to the caller and retains encrypted intake" do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Validation")
    encrypted = encrypted_backup(workspace, project, "validation phrase")
    {:ok, attempt} = RestoreIntake.start(workspace, "hosted", encrypted)

    assert {:ok, validating, package} =
             RestoreIntake.begin_validation(workspace, attempt.id, "validation phrase")

    assert validating.status == "validating"
    assert package.project.content["id"] == project.id
    assert {:ok, retained} = RestoreIntake.get(workspace, attempt.id)
    assert retained.status == "validating"
    assert retained.encrypted_package == encrypted
  end

  test "incorrect passphrase is opaque and deletes the hosted attempt" do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Wrong phrase")
    encrypted = encrypted_backup(workspace, project, "right phrase")
    {:ok, attempt} = RestoreIntake.start(workspace, "hosted", encrypted)

    assert {:error, :invalid_package_or_passphrase} =
             RestoreIntake.begin_validation(workspace, attempt.id, "wrong phrase")

    assert {:error, :not_found} = RestoreIntake.get(workspace, attempt.id)
  end

  test "cancellation, explicit failure, and completion immediately delete all terminal attempts" do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Cleanup")
    encrypted = encrypted_backup(workspace, project, "cleanup phrase")

    for terminal <- [&RestoreIntake.cancel/2, &RestoreIntake.fail/2, &RestoreIntake.complete/2] do
      {:ok, attempt} = RestoreIntake.start(workspace, "hosted", encrypted)
      assert :ok = terminal.(workspace, attempt.id)
      assert {:error, :not_found} = RestoreIntake.get(workspace, attempt.id)
    end
  end

  test "destination authorization is independent from package control" do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Destination")
    encrypted = encrypted_backup(workspace, project, "destination phrase")
    {:ok, device_workspace} = Devices.establish_workspace()

    assert {:error, :unauthorized_destination} =
             RestoreIntake.start(workspace, "device", encrypted)

    assert {:error, :unauthorized_destination} =
             RestoreIntake.start(device_workspace, "hosted", encrypted)

    assert Repo.aggregate(Portability.ImportAttempt, :count) == 0
    assert Devices.get_import_attempt(Ecto.UUID.generate()) == {:error, :not_found}
  end

  defp encrypted_backup(authority, project, passphrase) do
    {:ok, package} = BackupSnapshot.build(authority, project.id)
    {:ok, encrypted} = PackageEncryption.encrypt(package, passphrase)
    encrypted
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_restore_intake_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
